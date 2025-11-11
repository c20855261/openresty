-- daily_ip_stats.lua (v3-style, 修正版)
-- 功能重點：
--  - 下拉選擇日期（過去 14 天）
--  - POST 操作後使用 PRG (redirect)，並在頁面顯示 msg
--  - 操作日誌存入 Redis list (ops_log) 並顯示最近紀錄；也會 append /tmp/daily_ip_stats_ops.log（若可寫）
--  - 顯示每個 IP 的 Region（先查 Redis 快取 geo:<ip>，沒有才呼叫 ip-api.com 並快取）
--  - whitelist file 無法寫入時 fallback 到 Redis set 'whitelist:set'
--
local redis = require "resty.redis"
local http = require "resty.http"
local cjson = require "cjson.safe"
local cfg = require "config"

local ngx_escape = ngx.escape_uri

-- 配置（以 config 為準）
local REDIS_HOST = cfg.redis_host or "10.32.0.21"
local REDIS_PORT = cfg.redis_port or 6379
local SECONDARY_REDIS_HOST = cfg.secondary_redis_host or ""
local SECONDARY_REDIS_PORT = cfg.secondary_redis_port or 6379
local WHITELIST_FILE = cfg.whitelist_file or "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"
local DAILY_KEY_PREFIX = "daily:ipcounts:"
local DEFAULT_TOP = 50
local DATE_RANGE_DAYS = 14
local OPS_LOG_LIST = "ops_log"
local OPS_LOG_MAX = 100
local ADMIN_TOKEN = ""  -- 若需，填入 token
local BAN_TTL = cfg.ban_ttl or cfg.ban_time or 3600  -- 與 block_ip.lua 的 ban_time 建議統一為 config.ban_time

-- helpers
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
    if not SECONDARY_REDIS_HOST or SECONDARY_REDIS_HOST == "" then return nil, "no secondary" end
    return connect_redis(SECONDARY_REDIS_HOST, SECONDARY_REDIS_PORT)
end

local function daily_key_for_date(date_str) return DAILY_KEY_PREFIX .. date_str end

-- whitelist file read/write (file first, fallback to redis set)
local function read_whitelist_from_file()
    local t = {}
    local f = io.open(WHITELIST_FILE, "r")
    if not f then return nil, "open_failed" end
    for line in f:lines() do
        local s = line:match("^%s*(.-)%s*$")
        if s ~= "" and not s:match("^#") then t[s] = true end
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
    -- fallback to redis set
    local red, err = try_redis_connect()
    if not red then return {}, "none" end
    local res, rerr = red:smembers("whitelist:set")
    red:set_keepalive(10000, 100)
    if not res then return {}, "none" end
    local out = {}
    for _, ip in ipairs(res) do out[ip] = true end
    return out, "redis"
end

local function write_whitelist(tbl)
    local ok, where = write_whitelist_to_file(tbl)
    if ok then return true, where end
    -- fallback to redis
    local red, err = try_redis_connect()
    if not red then return nil, "redis_connect_failed:" .. tostring(err) end
    red:del("whitelist:set")
    for ip, _ in pairs(tbl) do red:sadd("whitelist:set", ip) end
    red:set_keepalive(10000, 100)
    return true, "redis"
end

-- ops log push (Redis list + local append)
local function push_ops_log(entry)
    local s = cjson.encode(entry) or tostring(entry)
    local red, err = try_redis_connect()
    if red then
        pcall(function()
            red:lpush(OPS_LOG_LIST, s)
            red:ltrim(OPS_LOG_LIST, 0, OPS_LOG_MAX - 1)
            red:set_keepalive(10000, 100)
        end)
    end
    -- append local file if possible
    pcall(function()
        local f = io.open("/tmp/daily_ip_stats_ops.log", "a+")
        if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. s .. "\n"); f:close() end
    end)
end

-- geo lookup: from Redis cache geo:<ip> else call ip-api.com and cache for 24h
local function get_geo_info_for_ip(red, ip)
    if not ip or ip == "" then return "unknown" end
    local cache_key = "geo:" .. ip
    if red then
        local v = red:get(cache_key)
        if v and v ~= ngx.null then return v end
    end
    -- call ip-api.com
    local httpc = http.new()
    httpc:set_timeout(1500)
    local ok, resp = pcall(function() return httpc:request_uri("http://ip-api.com/json/" .. ngx.escape_uri(ip) .. "?fields=status,country,regionName,city,countryCode", { method = "GET", keepalive = false }) end)
    local out = "unknown"
    if ok and resp and resp.status == 200 and resp.body then
        local j = cjson.decode(resp.body)
        if j and j.status == "success" then
            local parts = {}
            if j.country then table.insert(parts, j.country) end
            if j.regionName and j.regionName ~= "" then table.insert(parts, j.regionName) end
            if j.city and j.city ~= "" then table.insert(parts, j.city) end
            if j.countryCode then table.insert(parts, "(" .. j.countryCode .. ")") end
            out = table.concat(parts, ", ")
            -- cache in redis 24h
            if red then
                pcall(function() red:setex(cache_key, 86400, out) end)
            end
        end
    end
    return out
end

local function html_escape(s)
    if not s then return "" end
    return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

-- parse
local args = ngx.req.get_uri_args()
local date = args.date or os.date("%Y%m%d")
local top_n = tonumber(args.top) or DEFAULT_TOP
local fmt = (args.format or "html"):lower()
local msg = args.msg or ""

-- POST: handle actions then PRG redirect with msg (so user returns to list)
if ngx.req.get_method() == "POST" then
    ngx.req.read_body()
    local post = ngx.req.get_post_args()
    local action = post.action or ""
    local ip = (post.ip or ""):match("^%s*(.-)%s*$")
    local provided_token = post.admin_token or ""
    if ADMIN_TOKEN ~= "" and provided_token ~= ADMIN_TOKEN then
        push_ops_log({ time = os.date("%Y-%m-%d %H:%M:%S"), action = action, ip = ip, result = "invalid admin_token" })
        return ngx.redirect("/daily_ip_stats?date=" .. ngx_escape(date) .. "&top=" .. tostring(top_n) .. "&msg=" .. ngx_escape_uri("invalid admin_token"))
    end
    if action == "" or ip == "" then
        push_ops_log({ time = os.date("%Y-%m-%d %H:%M:%S"), action = action, ip = ip, result = "missing action or ip" })
        return ngx.redirect("/daily_ip_stats?date=" .. ngx_escape(date) .. "&top=" .. tostring(top_n) .. "&msg=" .. ngx_escape_uri("missing action or ip"))
    end

    local result = { ok = false, action = action, ip = ip }
    if action == "add_whitelist" then
        local wl, src = read_whitelist()
        wl[ip] = true
        local ok, where = write_whitelist(wl)
        if ok then result.ok = true; result.msg = "added to whitelist (stored in " .. where .. ")" else result.msg = "write failed: "..tostring(where) end

    elseif action == "remove_whitelist" then
        local wl, src = read_whitelist()
        if wl[ip] then wl[ip] = nil
            local ok, where = write_whitelist(wl)
            if ok then result.ok = true; result.msg = "removed from whitelist (stored in " .. where .. ")" else result.msg = "write failed: "..tostring(where) end
        else result.msg = "ip not in whitelist" end

    elseif action == "add_blacklist" then
        local red, err = try_redis_connect()
        if not red then result.msg = "redis connect failed: "..tostring(err)
        else
            local ok, err = red:setex("ban:" .. ip, BAN_TTL, "1")
            if ok then result.ok = true; result.msg = "added to blacklist (ban set)" else result.msg = "redis setex failed: "..tostring(err) end
            red:set_keepalive(10000, 100)
        end

    elseif action == "remove_blacklist" then
        local total_deleted = 0
        local red, err = try_redis_connect()
        if red then
            local d, derr = red:del("ban:" .. ip)
            total_deleted = total_deleted + (tonumber(d) or 0)
            red:set_keepalive(10000, 100)
        end
        if SECONDARY_REDIS_HOST and SECONDARY_REDIS_HOST ~= "" then
            local srd, serr = try_secondary_redis()
            if srd then
                local d2, derr2 = srd:del("ban:" .. ip)
                total_deleted = total_deleted + (tonumber(d2) or 0)
                srd:set_keepalive(10000, 100)
            end
        end
        -- confirm primary
        local chk, chkerr = try_redis_connect()
        local still_exists = false
        if chk then
            local v = chk:get("ban:" .. ip)
            if v and v ~= ngx.null then still_exists = true end
            chk:set_keepalive(10000, 100)
        end
        if total_deleted > 0 and not still_exists then
            result.ok = true; result.msg = "removed ban key(s): " .. tostring(total_deleted)
        elseif total_deleted > 0 and still_exists then
            result.ok = false; result.msg = "deleted from some nodes but still exists on primary"
        else
            result.ok = false; result.msg = "ban key not found"
        end

    else
        result.msg = "unknown action"
    end

    push_ops_log({ time = os.date("%Y-%m-%d %H:%M:%S"), action = action, ip = ip, result = result.msg })
    return ngx.redirect("/daily_ip_stats?date=" .. ngx_escape(date) .. "&top=" .. tostring(top_n) .. "&msg=" .. ngx_escape_uri(result.msg))
end

-- GET: render
local red, rerr = try_redis_connect()
if not red then
    if fmt == "json" then ngx.status = 500; ngx.say(cjson.encode({ error = "redis connect failed", reason = rerr })); return
    else ngx.header.content_type = "text/html; charset=utf-8"; ngx.say("<h3>Redis connect failed: "..html_escape(tostring(rerr)).."</h3>"); return end
end

local key = daily_key_for_date(date)
local res, err = red:zrevrange(key, 0, top_n - 1, "WITHSCORES")
if not res and err then red:set_keepalive(10000,100); ngx.status = 500; ngx.say(cjson.encode({ error = "redis zrevrange failed", reason = err })); return end

local rows = {}
if res then
    for i = 1, #res, 2 do
        local member = res[i]
        local score = tonumber(res[i+1]) or 0
        local domain, ip = member:match("^([^:]+):(.+)$")
        if not domain then domain = "unknown"; ip = member end
        table.insert(rows, { domain = domain, ip = ip, count = score })
    end
end

-- load whitelist for display
local wl_tbl, wl_src = read_whitelist()
local whitelist_list = {}
for ip, _ in pairs(wl_tbl) do table.insert(whitelist_list, ip) end

-- load recent ops (from Redis)
local ops = {}
do
    local lres, lerr = red:lrange(OPS_LOG_LIST, 0, 49)
    if lres then
        for _, raw in ipairs(lres) do
            local ok, parsed = pcall(cjson.decode, raw)
            if ok and parsed then table.insert(ops, parsed) else table.insert(ops, { raw = raw }) end
        end
    end
end

-- enrich rows with geo info (use redis geo cache if possible)
for _, r in ipairs(rows) do
    local geoinfo = get_geo_info_for_ip(red, r.ip)
    r.region = geoinfo
end

red:set_keepalive(10000,100)

-- JSON output
if fmt == "json" then
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.say(cjson.encode({ date = date, top_n = top_n, rows = rows, whitelist = whitelist_list, ops = ops }))
    return
end

-- HTML output
ngx.header.content_type = "text/html; charset=utf-8"
ngx.say("<!doctype html><html><head><meta charset='utf-8'><title>Daily IP Stats - " .. html_escape(date) .. "</title>")
ngx.say([[
<style>
body{font-family:Arial,Helvetica,sans-serif;margin:18px}
table{border-collapse:collapse;width:100%;margin-top:12px}
th,td{border:1px solid #ddd;padding:6px}
th{background:#f4f4f4}
.controls{display:flex;gap:12px;align-items:center;margin-bottom:12px}
.form-inline{display:inline-flex;gap:6px;align-items:center}
.notice{padding:8px;background:#f8f8f8;border:1px solid #eee;margin-top:8px}
.ops{margin-top:12px;border:1px solid #eee;padding:8px;background:#fafafa}
.small{font-size:0.9em;color:#666}
</style>
</head><body>
]])
ngx.say("<h2>Daily IP Stats for " .. html_escape(date) .. " (top " .. tostring(top_n) .. ")</h2>")
if msg and msg ~= "" then ngx.say("<div class='notice'><strong>Message:</strong> " .. html_escape(msg) .. "</div>") end

-- date selector
ngx.say("<div class='controls'><form id='dateForm' class='form-inline' method='get' action=''>")
ngx.say("<label for='date'>Date:</label>")
ngx.say("<select id='date' name='date' onchange='document.getElementById(\"dateForm\").submit()'>")
for i = 0, DATE_RANGE_DAYS-1 do
    local ts = os.time() - (86400 * i)
    local d = os.date("%Y%m%d", ts)
    local sel = (d == date) and " selected" or ""
    ngx.say("<option value='"..d.."'"..sel..">"..d.."</option>")
end
ngx.say("</select>")
ngx.say("<label for='top'> Top:</label>")
ngx.say("<input id='top' name='top' value='" .. tostring(top_n) .. "' size='4'/>")
ngx.say("<input type='submit' value='Show'/>")
ngx.say("</form><div class='form-inline'><a href='?date=" .. html_escape(date) .. "&top=" .. tostring(top_n) .. "&format=json'>JSON</a></div></div>")

-- management form
ngx.say("<div style='margin-top:10px'><h3>Manage IP (Whitelist / Blacklist)</h3>")
ngx.say("<div class='small'>注意：操作會立即生效，建議把此頁置於內網或搭配 nginx auth。</div>")
ngx.say([[
<form id='manageForm' method='post' action='' style='margin-top:8px'>
<input type='text' id='ip_input' name='ip' placeholder='輸入 IP (例: 1.2.3.4)' style='width:200px;padding:4px' required />
<select id='action_select' name='action' style='padding:4px'>
  <option value='add_whitelist'>Add to Whitelist</option>
  <option value='remove_whitelist'>Remove from Whitelist</option>
  <option value='add_blacklist'>Add to Blacklist (ban)</option>
  <option value='remove_blacklist'>Remove from Blacklist</option>
</select>
]])
if ADMIN_TOKEN ~= "" then ngx.say("<input type='password' name='admin_token' placeholder='admin_token' style='padding:4px;margin-left:6px'/>") end
ngx.say([[<input type='submit' value='Execute' style='margin-left:6px;padding:6px'/></form>]])

ngx.say("<div class='notice'><strong>Whitelist (source: file then redis fallback):</strong><br/>")
if #whitelist_list == 0 then ngx.say("（空）") else for _, ip in ipairs(whitelist_list) do ngx.say(html_escape(ip) .. " ") end end
ngx.say("</div></div>")

-- table with region column
ngx.say("<table><thead><tr><th>#</th><th>Domain</th><th>IP</th><th>Region</th><th>Count</th></tr></thead><tbody>")
if #rows == 0 then
    ngx.say("<tr><td colspan='5' style='text-align:center'>No data for " .. html_escape(date) .. "</td></tr>")
else
    for idx, r in ipairs(rows) do
        ngx.say("<tr><td>"..idx.."</td><td>"..html_escape(r.domain).."</td><td>"..html_escape(r.ip).."</td><td>"..html_escape(r.region).."</td><td>"..tostring(r.count) .."</td></tr>")
    end
end
ngx.say("</tbody></table>")

-- ops log
ngx.say("<div class='ops'><h4>Recent Operations</h4>")
if #ops == 0 then ngx.say("<div class='small'>No operations logged yet.</div>")
else
    ngx.say("<ul class='small'>")
    for _, e in ipairs(ops) do
        local time = e.time or e[1] or os.date("%Y-%m-%d %H:%M:%S")
        local action = e.action or "-"
        local ip = e.ip or "-"
        local res = e.result or e.msg or "-"
        ngx.say("<li>" .. html_escape(time) .. " - " .. html_escape(action) .. " " .. html_escape(ip) .. " → " .. html_escape(tostring(res)) .. "</li>")
    end
    ngx.say("</ul>")
end
ngx.say("</div>")

ngx.say("<p class='small'>Notes: whitelist file used if writable, otherwise stored in Redis set 'whitelist:set'. Blacklist stored as Redis key 'ban:&lt;ip&gt;'. Recent ops in Redis list '"..html_escape(OPS_LOG_LIST).."'.</p>")
ngx.say([[
<script>document.getElementById('ip_input').focus();</script>
]])
ngx.say("</body></html>")
