local redis = require "resty.redis"
local http = require "resty.http"
local cjson = require "cjson.safe"
local cfg = require "config"

local ngx_escape = ngx.escape_uri

-- 配置
local REDIS_HOST = cfg.redis_host or "127.0.0.1"
local REDIS_PORT = cfg.redis_port or 6379
local SECONDARY_REDIS_HOST = cfg.secondary_redis_host or ""
local SECONDARY_REDIS_PORT = cfg.secondary_redis_port or 6379
local WHITELIST_FILE = cfg.whitelist_file or "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"
local DAILY_KEY_PREFIX = "daily:ipcounts:"
local DEFAULT_TOP = 30
local DATE_RANGE_DAYS = 14
local OPS_LOG_LIST = "ops_log"
local OPS_LOG_MAX = 15
local ADMIN_TOKEN = "" 
local BAN_TTL = cfg.ban_ttl or cfg.ban_time or 3600

---------------------------------------------------------------------
-- Redis Connect
---------------------------------------------------------------------
local function connect_redis(host, port)
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(host or REDIS_HOST, port or REDIS_PORT)
    if not ok then return nil, err end
    return red, nil
end

local function try_redis_connect()
    return connect_redis(REDIS_HOST, REDIS_PORT)
end

local function try_secondary_redis()
    if not SECONDARY_REDIS_HOST or SECONDARY_REDIS_HOST == "" then
        return nil, "no secondary"
    end
    return connect_redis(SECONDARY_REDIS_HOST, SECONDARY_REDIS_PORT)
end

local function daily_key_for_date(date_str)
    return DAILY_KEY_PREFIX .. date_str
end

---------------------------------------------------------------------
-- IP 驗證函數（提前定義）
---------------------------------------------------------------------
local function is_valid_ip(ip)
    if not ip or ip == "" then return false end
    
    local ipv4_pattern = "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
    local a, b, c, d = ip:match(ipv4_pattern)
    if a and b and c and d then
        a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        if a and a <= 255 and b and b <= 255 and c and c <= 255 and d and d <= 255 then
            return true, "ipv4"
        end
    end
    
    if ip:match("^[%da-fA-F:]+$") and ip:find(":") then
        return true, "ipv6"
    end
    
    return false, "invalid"
end

---------------------------------------------------------------------
-- Whitelist File Read/Write
---------------------------------------------------------------------
local function read_whitelist_from_file()
    local t = {}
    local f = io.open(WHITELIST_FILE, "r")
    if not f then return nil, "open_failed" end

    for line in f:lines() do
        -- 移除所有空白字符（包括可能的 \r \n）
        local s = line:match("^%s*(.-)%s*$")
        if s and s ~= "" and not s:match("^#") then 
            -- 額外驗證：確保是有效的 IP 格式
            local valid, _ = is_valid_ip(s)
            if valid then
                t[s] = true
            else
                ngx.log(ngx.WARN, "Invalid IP in whitelist file, skipped: ", s)
            end
        end
    end

    f:close()
    return t, "file"
end

local function write_whitelist_to_file(tbl)
    local f, err = io.open(WHITELIST_FILE, "w+")
    if not f then return nil, err end

    for ip, _ in pairs(tbl) do f:write(ip .. "\n") end
    f:close()
    return true, "file"
end

local function read_whitelist()
    local tbl, src = read_whitelist_from_file()
    if tbl then return tbl, src end

    local red = try_redis_connect()
    if not red then return {}, "none" end

    local res = red:smembers("whitelist:set")
    red:set_keepalive(10000,100)

    if not res then return {}, "none" end

    local out = {}
    for _, ip in ipairs(res) do out[ip] = true end
    return out, "redis"
end

local function write_whitelist(tbl)
    local ok = write_whitelist_to_file(tbl)
    if ok then return true, "file" end

    local red, err = try_redis_connect()
    if not red then return nil, "redis_connect_failed:" .. tostring(err) end

    red:del("whitelist:set")
    for ip,_ in pairs(tbl) do
        red:sadd("whitelist:set", ip)
    end
    red:set_keepalive(10000,100)
    return true, "redis"
end

---------------------------------------------------------------------
-- OPS LOG
---------------------------------------------------------------------
local function push_ops_log(entry)
    local s = cjson.encode(entry) or tostring(entry)

    local red = try_redis_connect()
    if red then
        pcall(function()
            red:lpush(OPS_LOG_LIST, s)
            red:ltrim(OPS_LOG_LIST, 0, OPS_LOG_MAX - 1)
            red:set_keepalive(10000, 100)
        end)
    end

    pcall(function()
        local f = io.open("/tmp/daily_ip_stats_ops.log", "a+")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. s .. "\n")
            f:close()
        end
    end)
end

---------------------------------------------------------------------
-- GEO Lookup
---------------------------------------------------------------------
local function get_geo_info_for_ip(red, ip)
    if not ip or ip == "" then return "unknown" end

    local cache_key = "geo:" .. ip

    if red then
        local ok, v = pcall(function() return red:get(cache_key) end)
        if ok and v and v ~= ngx.null then return v end
    end

    local okgeo, geomod = pcall(require, "geo_mapping")
    if okgeo and geomod and geomod.country_map then
        local httpc = http.new()
        httpc:set_timeout(1000)
        local ok, resp = pcall(function()
            return httpc:request_uri(
                "http://ip-api.com/json/" .. ngx_escape(ip) ..
                "?fields=status,country,regionName,city,countryCode",
                { method="GET", keepalive=false }
            )
        end)

        if ok and resp and resp.status == 200 then
            local j = cjson.decode(resp.body)
            if j and j.status == "success" then
                local country_en = j.country or ""
                local cn = geomod.country_map[country_en]
                         or geomod.country_map[country_en:lower()]
                local regionName = j.regionName or ""
                local city = j.city or ""
                local code = j.countryCode or ""

                local out
                if cn then
                    local parts = {cn}
                    if regionName ~= "" then table.insert(parts, regionName) end
                    if city ~= "" then table.insert(parts, city) end
                    if code ~= "" then table.insert(parts, "("..code..")") end
                    out = table.concat(parts, "，")
                else
                    local parts = {}
                    if country_en ~= "" then table.insert(parts, country_en) end
                    if regionName ~= "" then table.insert(parts, regionName) end
                    if city ~= "" then table.insert(parts, city) end
                    if code ~= "" then table.insert(parts, "("..code..")") end
                    out = table.concat(parts, ", ")
                end

                if red then pcall(function() red:setex(cache_key, 86400, out) end) end
                return out
            end
        end
    end

    local httpc = http.new()
    httpc:set_timeout(1500)
    local ok, resp = pcall(function()
        return httpc:request_uri(
            "http://ip-api.com/json/" .. ngx_escape(ip) ..
            "?fields=status,country,regionName,city,countryCode",
            { method="GET", keepalive=false }
        )
    end)

    if ok and resp and resp.status == 200 then
        local j = cjson.decode(resp.body)
        if j and j.status == "success" then
            local parts = {}
            if j.country then table.insert(parts, j.country) end
            if j.regionName and j.regionName ~= "" then table.insert(parts, j.regionName) end
            if j.city and j.city ~= "" then table.insert(parts, j.city) end
            if j.countryCode then table.insert(parts, "("..j.countryCode..")") end
            local out = table.concat(parts, ", ")
            if red then pcall(function() red:setex(cache_key, 86400, out) end) end
            return out
        end
    end

    return "unknown"
end

---------------------------------------------------------------------
local function html_escape(s)
    if not s then return "" end
    return s:gsub("&","&amp;"):gsub("<","&lt;")
            :gsub(">","&gt;"):gsub('"',"&quot;")
            :gsub("'","&#39;")
end

---------------------------------------------------------------------
-- Parse Args
---------------------------------------------------------------------
local args = ngx.req.get_uri_args()
local date = args.date or os.date("%Y%m%d")
local top_n = tonumber(args.top) or DEFAULT_TOP
local fmt = (args.format or "html"):lower()
local msg = args.msg or ""

---------------------------------------------------------------------
-- POST handler
---------------------------------------------------------------------
if ngx.req.get_method() == "POST" then
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()
    
    if body_data then
        ngx.log(ngx.INFO, "POST body: ", body_data)
    end
    
    local post, post_err = ngx.req.get_post_args(100)
    
    if not post then
        push_ops_log({error="post_parse_failed", reason=tostring(post_err)})
        return ngx.redirect("/daily_ip_stats?date="..ngx_escape(date)
            .."&top="..tostring(top_n)
            .."&msg="..ngx_escape("POST parse failed: "..tostring(post_err)))
    end

    local action = post.action or ""
    local ip_raw = post.ip or ""
    local ip = ip_raw:match("^%s*(.-)%s*$")
    local provided_token = post.admin_token or ""
    
    ngx.log(ngx.INFO, "Received - action: ", action, ", ip_raw: '", ip_raw, "', ip: '", ip, "'")

    if ADMIN_TOKEN ~= "" and provided_token ~= ADMIN_TOKEN then
        push_ops_log({action=action, ip=ip, result="invalid admin_token"})
        return ngx.redirect("/daily_ip_stats?date="..ngx_escape(date)
            .."&top="..tostring(top_n)
            .."&msg="..ngx_escape("invalid admin_token"))
    end

    if action == "" then
        push_ops_log({action=action, ip=ip, result="missing action"})
        return ngx.redirect("/daily_ip_stats?date="..ngx_escape(date)
            .."&top="..tostring(top_n)
            .."&msg="..ngx_escape("missing action"))
    end
    
    if ip == "" then
        push_ops_log({action=action, ip=ip, result="missing ip"})
        return ngx.redirect("/daily_ip_stats?date="..ngx_escape(date)
            .."&top="..tostring(top_n)
            .."&msg="..ngx_escape("missing ip"))
    end
    
    local valid, ip_type = is_valid_ip(ip)
    if not valid then
        push_ops_log({action=action, ip=ip, result="invalid_ip_format"})
        return ngx.redirect("/daily_ip_stats?date="..ngx_escape(date)
            .."&top="..tostring(top_n)
            .."&msg="..ngx_escape("Invalid IP format: "..ip))
    end

    local result = { ok=false, action=action, ip=ip, ip_type=ip_type }

    if action == "add_whitelist" then
        local wl = read_whitelist()
        wl[ip] = true
        local ok, where = write_whitelist(wl)
        result.ok = ok
        result.msg = ok and ("added to whitelist ("..where.."): "..ip)
                     or ("write failed: "..tostring(where))

    elseif action == "remove_whitelist" then
        local wl = read_whitelist()
        if wl[ip] then
            wl[ip] = nil
            local ok, where = write_whitelist(wl)
            result.ok = ok
            result.msg = ok and ("removed from whitelist ("..where.."): "..ip)
                         or ("write failed: "..tostring(where))
        else
            result.msg = "ip not in whitelist: "..ip
        end

    elseif action == "add_blacklist" then
        local red, err = try_redis_connect()
        if not red then
            result.msg = "redis connect failed: "..tostring(err)
        else
            local ban_key = "ban:"..ip
            ngx.log(ngx.INFO, "Setting Redis key: ", ban_key)
            local ok, err = red:setex(ban_key, BAN_TTL, "1")
            result.ok = ok
            result.msg = ok and ("added to blacklist: "..ip.." (key: "..ban_key..")")
                         or ("redis setex failed: "..tostring(err))
            
            if ok then
                local verify = red:get(ban_key)
                if verify == ngx.null or not verify then
                    result.ok = false
                    result.msg = "redis set succeeded but verify failed for key: "..ban_key
                end
            end
            
            red:set_keepalive(10000,100)
        end

    elseif action == "remove_blacklist" then
        local total_deleted = 0
        local ban_key = "ban:"..ip

        local red = try_redis_connect()
        if red then
            ngx.log(ngx.INFO, "Deleting Redis key: ", ban_key)
            local d = red:del(ban_key)
            total_deleted = total_deleted + (tonumber(d) or 0)
            red:set_keepalive(10000,100)
        end

        if SECONDARY_REDIS_HOST ~= "" then
            local srd = try_secondary_redis()
            if srd then
                local d2 = srd:del(ban_key)
                total_deleted = total_deleted + (tonumber(d2) or 0)
                srd:set_keepalive(10000,100)
            end
        end

        local chk = try_redis_connect()
        local still_exists = false
        if chk then
            local v = chk:get(ban_key)
            still_exists = (v and v ~= ngx.null)
            chk:set_keepalive(10000,100)
        end

        if total_deleted > 0 and not still_exists then
            result.ok = true
            result.msg = "removed ban key: "..ban_key.." (deleted: "..tostring(total_deleted)..")"
        elseif total_deleted > 0 and still_exists then
            result.msg = "deleted from some nodes but key still exists: "..ban_key
        else
            result.msg = "ban key not found: "..ban_key
        end

    else
        result.msg = "unknown action: "..action
    end

    push_ops_log(result)

    return ngx.redirect("/daily_ip_stats?date="..ngx_escape(date)
        .."&top="..tostring(top_n)
        .."&msg="..ngx_escape(result.msg))
end

---------------------------------------------------------------------
-- GET handler
---------------------------------------------------------------------
local red, rerr = try_redis_connect()
if not red then
    if fmt == "json" then
        ngx.status = 500
        ngx.say(cjson.encode({error="redis connect failed", reason=rerr}))
    else
        ngx.header.content_type = "text/html"
        ngx.say("<h3>Redis connect failed: "..html_escape(tostring(rerr)).."</h3>")
    end
    return
end

local key = daily_key_for_date(date)
local res, err = red:zrevrange(key, 0, top_n - 1, "WITHSCORES")
if not res then
    red:set_keepalive(10000,100)
    ngx.status = 500
    ngx.say(cjson.encode({error="zrevrange failed", reason=err}))
    return
end

local rows = {}
for i = 1, #res, 2 do
    local member = res[i]
    local score = tonumber(res[i+1]) or 0
    local domain, ip = member:match("^([^:]+):(.+)$")
    if not domain then domain = "unknown"; ip = member end
    table.insert(rows, {domain=domain, ip=ip, count=score})
end

local wl_tbl, wl_source = read_whitelist()
local whitelist_list = {}
for ip,_ in pairs(wl_tbl) do 
    -- 調試日誌：記錄讀取到的 IP
    ngx.log(ngx.INFO, "Whitelist IP from ", wl_source, ": '", ip, "' (length: ", #ip, ")")
    table.insert(whitelist_list, ip) 
end

-- 排序以便檢查
table.sort(whitelist_list)

local ops = {}
do
    local lres = red:lrange(OPS_LOG_LIST, 0, 49)
    if lres then
        for _, raw in ipairs(lres) do
            local ok, parsed = pcall(cjson.decode, raw)
            table.insert(ops, ok and parsed or {raw=raw})
        end
    end
end

-- Ban list retrieval
local ban_list = {}
local ban_set = {}
do
    local cursor = "0"
    local scan_count = 0
    local max_iterations = 1000
    
    repeat
        local r, scan_err = red:scan(cursor, "MATCH", "ban:*", "COUNT", 100)
        scan_count = scan_count + 1
        
        if not r then
            ngx.log(ngx.WARN, "SCAN failed, using KEYS fallback: ", tostring(scan_err))
            local kres, kerr = red:keys("ban:*")
            if kres and type(kres) == "table" then
                for _, k in ipairs(kres) do
                    if type(k) == "string" and k:match("^ban:.+$") then
                        local ip = k:match("^ban:(.+)$")
                        if ip and not ban_set[ip] then
                            ban_set[ip] = true
                            table.insert(ban_list, ip)
                        end
                    end
                end
            end
            break
        else
            local next_cursor, keys_arr
            
            if type(r) == "table" then
                if #r >= 2 then
                    next_cursor = tostring(r[1])
                    keys_arr = r[2]
                elseif #r == 1 then
                    next_cursor = "0"
                    keys_arr = r[1]
                else
                    next_cursor = "0"
                    keys_arr = {}
                end
            else
                next_cursor = "0"
                keys_arr = {}
            end
            
            if type(keys_arr) == "table" then
                for _, k in ipairs(keys_arr) do
                    if type(k) == "string" and k:match("^ban:.+$") then
                        local ip = k:match("^ban:(.+)$")
                        if ip and not ban_set[ip] then
                            ban_set[ip] = true
                            table.insert(ban_list, ip)
                        end
                    end
                end
            end
            
            cursor = next_cursor
        end
        
    until cursor == "0" or cursor == "nil" or scan_count >= max_iterations
end

table.sort(ban_list, function(a, b)
    local a_parts = {}
    local b_parts = {}
    
    for num in a:gmatch("%d+") do
        table.insert(a_parts, tonumber(num) or 0)
    end
    for num in b:gmatch("%d+") do
        table.insert(b_parts, tonumber(num) or 0)
    end
    
    for i = 1, math.max(#a_parts, #b_parts) do
        local a_val = a_parts[i] or 0
        local b_val = b_parts[i] or 0
        if a_val ~= b_val then
            return a_val < b_val
        end
    end
    
    return a < b
end)

for _, r in ipairs(rows) do
    r.region = get_geo_info_for_ip(red, r.ip) or "unknown"
end

red:set_keepalive(10000,100)

---------------------------------------------------------------------
-- JSON Output
---------------------------------------------------------------------
if fmt == "json" then
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        date=date, top_n=top_n,
        rows=rows,
        whitelist=whitelist_list,
        ops=ops,
        bans=ban_list
    }))
    return
end

---------------------------------------------------------------------
-- HTML Output
---------------------------------------------------------------------
ngx.header.content_type = "text/html; charset=utf-8"

ngx.say("<!doctype html><html><head><meta charset='utf-8'><title>Daily IP Stats - "
    ..html_escape(date).."</title>")

ngx.say([[
<style>
body{font-family:Arial;margin:18px}
table{border-collapse:collapse;width:100%;margin-top:12px}
th,td{border:1px solid #ddd;padding:6px}
th{background:#f4f4f4}
.controls{display:flex;gap:12px;align-items:center;margin-bottom:12px}
.form-inline{display:inline-flex;gap:6px;align-items:center}
.notice{padding:8px;background:#f8f8f8;border:1px solid #eee;margin-top:8px}
.ops{margin-top:12px;border:1px solid #eee;padding:8px;background:#fafafa}
.small{font-size:0.9em;color:#666}
.msg-success { background:#e0ffe0;border-left:4px solid #4CAF50;padding:10px;margin:10px 0; }
.msg-error   { background:#ffe0e0;border-left:4px solid #f44336;padding:10px;margin:10px 0; }
.ip-list{max-height:200px;overflow-y:auto;padding:8px;background:#fff;border:1px solid #ddd;border-radius:4px;font-family:monospace}
</style>
</head><body>
]])

ngx.say("<h2>Daily IP Stats for " .. html_escape(date) ..
        " (top " .. tostring(top_n) .. ")</h2>")

if msg ~= "" then
    local cls = "msg-success"
    if msg:lower():match("fail") or msg:lower():match("error") or msg:lower():match("invalid") then
        cls = "msg-error"
    end
    ngx.say("<div class='"..cls.."'><strong>訊息：</strong> " .. html_escape(msg) .. "</div>")
end

ngx.say("<div class='controls'><form id='dateForm' class='form-inline' method='get'>")

ngx.say("<label>Date:</label><select name='date' onchange='this.form.submit()'>")
for i = 0, DATE_RANGE_DAYS -1 do
    local d = os.date("%Y%m%d", os.time() - i*86400)
    ngx.say("<option value='"..d.."' "..(d==date and "selected" or "")..">"..d.."</option>")
end
ngx.say("</select>")

ngx.say("<label>Top:</label><input name='top' value='"..tostring(top_n).."' size='4'/>")
ngx.say("<input type='submit' value='Show'/>")
ngx.say("</form><div class='form-inline'><a href='?date="..
        html_escape(date).."&top="..tostring(top_n).."&format=json'>JSON</a></div></div>")

ngx.say("<div><h3>Manage IP (Whitelist / Blacklist)</h3>")
ngx.say("<div class='small'>注意：動作立即生效，建議用內網或 Nginx auth 保護。輸入完整 IP 地址</div>")

ngx.say("<form method='post' style='margin-top:8px'>")
ngx.say("<input type='hidden' name='admin_token' value='"..html_escape(ADMIN_TOKEN).."'>")
ngx.say("<div class='form-inline'>")
ngx.say("IP: <input type='text' name='ip' size='20' placeholder='例: 1.1.1.10' required autocomplete='off' />")
ngx.say("<select name='action' required>")
ngx.say("<option value=''>請選擇動作</option>")
ngx.say("<option value='add_whitelist'>新增白名單</option>")
ngx.say("<option value='remove_whitelist'>刪除白名單</option>")
ngx.say("<option value='add_blacklist'>新增黑名單</option>")
ngx.say("<option value='remove_blacklist'>刪除黑名單</option>")
ngx.say("</select>")
ngx.say("<input type='submit' value='執行'/>")
ngx.say("</div>")
ngx.say("</form>")
ngx.say("</div>")

ngx.say("<div style='display:flex;gap:18px;margin-top:12px'>")
ngx.say("<div style='flex:1' class='ops'><h4>Whitelist ("..tostring(#whitelist_list).." IPs)</h4>")
if #whitelist_list == 0 then
    ngx.say("<div class='small'>（空）</div>")
else
    ngx.say("<div class='ip-list'>")
    for i, ip in ipairs(whitelist_list) do
        -- 檢查 IP 格式並標記異常
        local valid, ip_type = is_valid_ip(ip)
        if valid then
            ngx.say("<span style='color:green'>&#10003;</span> "..html_escape(ip))
        else
            ngx.say("<span style='color:red;font-weight:bold'>&#10007; "..html_escape(ip).." (格式錯誤, 長度:"..tostring(#ip)..")</span>")
        end
        if i < #whitelist_list then ngx.say("<br/>") end
    end
    ngx.say("</div>")
    
    -- 如果有格式錯誤的 IP，顯示提示
    local has_invalid = false
    for _, ip in ipairs(whitelist_list) do
        local valid, _ = is_valid_ip(ip)
        if not valid then
            has_invalid = true
            break
        end
    end
    
    if has_invalid then
        ngx.say("<div class='small' style='margin-top:8px;color:#d9534f'>")
        ngx.say("提示：紅色標記的是格式錯誤的 IP，請檢查檔案內容")
        ngx.say("</div>")
    end
end
ngx.say("</div>")

ngx.say("<div style='flex:1' class='ops'><h4>Blacklist / Banned IPs ("..tostring(#ban_list).." IPs)</h4>")
if #ban_list == 0 then
    ngx.say("<div class='small'>（目前無 ban 記錄）</div>")
else
    ngx.say("<div class='ip-list'>")
    for i, ip in ipairs(ban_list) do
        local valid, ip_type = is_valid_ip(ip)
        if valid then
            ngx.say("<span style='color:green'>&#10003;</span> "..html_escape(ip))
        else
            ngx.say("<span style='color:red;font-weight:bold'>&#10007; "..html_escape(ip).." (格式錯誤)</span>")
        end
        if i < #ban_list then ngx.say("<br/>") end
    end
    ngx.say("</div>")
    ngx.say("<div class='small' style='margin-top:8px;color:#d9534f'>")
    ngx.say("提示：紅色標記的是格式錯誤的 IP，請手動清理 Redis")
    ngx.say("</div>")
end
ngx.say("</div>")
ngx.say("</div>")

ngx.say("<table><tr><th>Domain</th><th>IP</th><th>Count</th><th>Region</th></tr>")
if #rows == 0 then
    ngx.say("<tr><td colspan='4' style='text-align:center'>No data</td></tr>")
else
    for _, r in ipairs(rows) do
        ngx.say("<tr><td>"..html_escape(r.domain).."</td><td>"..
                html_escape(r.ip).."</td><td>"..tostring(r.count)..
                "</td><td>"..html_escape(r.region or "unknown").."</td></tr>")
    end
end
ngx.say("</table>")

ngx.say("<div class='ops'><h4>Recent Operations</h4><div class='small'>")
if #ops == 0 then
    ngx.say("（無操作紀錄）")
else
    for _, l in ipairs(ops) do
        ngx.say(html_escape(cjson.encode(l)) .. "<br/>")
    end
end
ngx.say("</div></div>")

ngx.say("</body></html>")

