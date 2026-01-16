-- log_error_block.lua (v6.1) - 修正：確保 daily:ipcounts 持續累計
-- 說明：
--  - 原因：之前的 ZINCRBY 與 daily JSON 更新僅在第一次 setnx 成功（is_new_ban==true）時執行，
--    因此只有「第一次 ban」會增加 daily:ipcounts，後續同 IP 的觸發不會再累計。
--  - 本次最小改動：把 daily JSON 更新與 zset (daily:ipcounts:DATE) 的 ZINCRBY 改為無條件執行（每次 async_ban_process 被呼叫時都執行），
--    但保留 setnx 只在第一次建立 ban 並只在第一次發送通知的行為（避免通知重複）。
--  - 這樣可以讓統計持續累計，但通知與 ban 行為仍由 setnx 控制（僅第一次通知 / 設 ban）。
--  - 小心：若系統其他路徑也會呼叫 ZINCRBY，請注意是否會造成雙重計數；若需要可加 dedupe 機制。

local cfg = require "config"
local redis = require "resty.redis"
local telegram = require "telegram"
local geo = require "geo_mapping"
local http = require "resty.http"
local cjson = require "cjson.safe"

-- === 設定區塊 ===
local TEST_MODE = false

local REDIS_HOST = cfg.redis_host or "127.0.0.1"
local REDIS_PORT = cfg.redis_port or 6379
local BAN_TTL = cfg.ban_time or 10800
local ERROR_WINDOW = cfg.error_window or 120
local DAILY_KEY_TTL_SECONDS = cfg.daily_ttl or (60 * 60 * 24 * 7) -- 預設 7 天
local WHITELIST_FILE = cfg.whitelist_file or "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"

local ERROR_THRESHOLDS = cfg.error_thresholds or {
    ["400"] = 30,
    ["401"] = 20,
    ["403"] = 50,
    ["404"] = 80
}

local shm = ngx.shared.error_block_dict
if not shm then
    ngx.log(ngx.ERR, "[log_error_block] shared dict 'error_block_dict' not defined in nginx.conf")
    return
end

-- === 輔助函數：白名單 ===
local function is_whitelisted(ip)
    if not ip then return false end
    local f = io.open(WHITELIST_FILE, "r")
    if not f then return false end
    for line in f:lines() do
        local s = line:match("^%s*(.-)%s*$")
        if s ~= "" and not s:match("^#") and s == ip then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

-- === 輔助函數：本地 Geo (無 I/O，可同步呼叫) ===
local function get_local_geo_info()
    local country = ngx.var.geoip2_data_country_name
    local city = ngx.var.geoip2_data_city_name or ""
    local code = ngx.var.geoip2_data_country_code or ""
    if country and country ~= "" and country ~= "Unknown" then
        local cname = geo.country_map[country] or country
        return cname .. (city ~= "" and ("，" .. city) or "") .. " (" .. code .. ")"
    end
    return nil
end

-- === 輔助函數：遠端 Geo (有 I/O，僅能在 Timer 呼叫) ===
local function get_remote_geo_info(ip)
    local httpc = http.new()
    httpc:set_timeout(1500)
    local ok, res = pcall(function()
        return httpc:request_uri(
            "http://ip-api.com/json/" .. ngx.escape_uri(ip) .. "?fields=status,country,city,countryCode",
            { method = "GET" }
        )
    end)
    if not ok or not res or res.status ~= 200 then
        ngx.log(ngx.WARN, "[log_error_block] remote geo API failed for ip=", tostring(ip))
        return "Unknown"
    end
    local j = cjson.decode(res.body)
    if not j or j.status ~= "success" then return "Unknown" end
    local api_country = j.country or "Unknown"
    local api_cname = geo.country_map[api_country] or api_country
    return string.format("%s，%s (%s)", api_cname, j.city or "", j.countryCode or "")
end

-- === Redis 連線 helper (使用於 timer handler) ===
local function redis_connect()
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil, err
    end
    return red, nil
end

-- === 非同步任務處理器 (Timer Handler) ===
-- 參數: (premature, ip, status, count, vhost, threshold, local_geo)
local function async_ban_process(premature, ip, status, count, vhost, threshold, local_geo)
    if premature then return end

    -- local date for keys (timer doesn't inherit caller locals)
    local date_str = os.date("%Y%m%d")
    ngx.log(ngx.NOTICE, "[log_error_block] async_ban_process start date=", date_str,
        " ip=", tostring(ip), " vhost=", tostring(vhost), " status=", tostring(status), " count=", tostring(count))

    -- double-check whitelist
    if is_whitelisted(ip) then
        ngx.log(ngx.NOTICE, "[log_error_block] IP whitelisted, skip async processing: ", tostring(ip))
        return
    end

    -- final geo (prefer local passed value)
    local final_geo = local_geo or get_remote_geo_info(ip)

    -- connect redis
    local red, err = redis_connect()
    if not red then
        ngx.log(ngx.ERR, "[log_error_block] redis connect failed in async: ", tostring(err))
        return
    end

    -- ban key using setnx to avoid races (we still try, but statistics update below is unconditional)
    local ban_key = "ban:" .. ip
    local setnx_ok, setnx_err = red:setnx(ban_key, "1")
    local is_new_ban = tonumber(setnx_ok) == 1

    -- === ALWAYS update per-IP daily JSON and zset counts ===
    do
        local daily_key = "daily:" .. date_str .. ":" .. ip
        local raw_data = red:get(daily_key)
        local stats = {
            ip = ip,
            geo = final_geo,
            conn_ban = 0,
            error_ban = 0,
            last_ban = os.date("%Y-%m-%d %H:%M:%S")
        }
        if raw_data and raw_data ~= ngx.null then
            local okd, decoded = pcall(cjson.decode, raw_data)
            if okd and type(decoded) == "table" then
                stats = decoded
                stats.last_ban = os.date("%Y-%m-%d %H:%M:%S")
                if (not stats.geo or stats.geo == "Unknown") and final_geo ~= "Unknown" then
                    stats.geo = final_geo
                end
            end
        end

        -- increase error_ban count each time async_ban_process runs (aligns with "increment per event")
        stats.error_ban = (stats.error_ban or 0) + 1

        local okset, errset = red:set(daily_key, cjson.encode(stats))
        if not okset then
            ngx.log(ngx.ERR, "[log_error_block] failed set daily key: ", tostring(errset))
        else
            pcall(function() red:expire(daily_key, DAILY_KEY_TTL_SECONDS) end)
        end

        -- always update the sorted-set for frontend
        local zkey = "daily:ipcounts:" .. date_str
        local member = tostring(vhost or "unknown") .. ":" .. tostring(ip)
        ngx.log(ngx.NOTICE, "[log_error_block DEBUG] about to zincrby zkey=", zkey, " member=", member)
        local okz, errz = red:zincrby(zkey, 1, member)
        if not okz then
            ngx.log(ngx.ERR, "[log_error_block DEBUG] zincrby failed for ", zkey, " member=", member, " err=", tostring(errz))
        else
            ngx.log(ngx.NOTICE, "[log_error_block DEBUG] zincrby ok for ", zkey, " member=", member, " result=", tostring(okz))
            local okr, rres = pcall(function() return red:zrevrange(zkey, 0, 4, "WITHSCORES") end)
            if okr and rres then
                ngx.log(ngx.NOTICE, "[log_error_block DEBUG] zrevrange for ", zkey, " -> ", cjson.encode(rres))
            end
            local ttl = red:ttl(zkey)
            ngx.log(ngx.NOTICE, "[log_error_block DEBUG] ttl for ", zkey, " -> ", tostring(ttl))
            if ttl == ngx.null or ttl == -1 then
                pcall(function() red:expire(zkey, DAILY_KEY_TTL_SECONDS) end)
            end
        end
    end

    -- === Now handle ban/notify only when newly banned ===
    if is_new_ban then
        pcall(function() red:expire(ban_key, BAN_TTL) end)
        ngx.log(ngx.NOTICE, "[log_error_block] Ban set for IP: ", ip, " TTL: ", BAN_TTL)

        -- prepare and send notification only once (protected by notify_key)
        local notify_key = "notify:ban:" .. ip
        local nok, nerr = red:setnx(notify_key, "1")
        if tonumber(nok) == 1 then
            pcall(function() red:expire(notify_key, BAN_TTL) end)

            local hostname = "unknown"
            pcall(function()
                local fh = io.popen("hostname")
                if fh then hostname = fh:read("*l") or hostname; fh:close() end
            end)
            local gateway_ip = "unknown"
            pcall(function()
                local fh = io.popen("curl -s -m 2 ifconfig.me")
                if fh then gateway_ip = fh:read("*l") or gateway_ip; fh:close() end
            end)

            local msg = string.format(
                "Time: %s\nHost: %s\nVhost: %s\nGateway_IP: %s\nBlocked_IP: %s\nIP_Location: %s\nStatus: %s\nCount: %s / %s\nBan_TTL: %ss",
                os.date("%Y-%m-%d %H:%M:%S"), hostname, tostring(vhost), gateway_ip, ip, tostring(final_geo), tostring(status), tostring(count), tostring(threshold), tostring(BAN_TTL)
            )

            if not TEST_MODE then
                local oktel, errtel = pcall(telegram.send, msg)
                if not oktel then
                    ngx.log(ngx.ERR, "[log_error_block] telegram.send failed: ", tostring(errtel))
                else
                    ngx.log(ngx.NOTICE, "[log_error_block] telegram notification queued for ip=", ip)
                end
            else
                ngx.log(ngx.NOTICE, "[TEST_MODE] Notification: \n", msg)
            end
        else
            ngx.log(ngx.NOTICE, "[log_error_block] notify_key exists, skip telegram for ip=", ip)
        end
    else
        ngx.log(ngx.NOTICE, "[log_error_block] ip already banned or setnx failed for ip=", tostring(ip))
    end

    -- set keepalive for redis
    pcall(function() red:set_keepalive(10000, 100) end)

    -- clear marker in shared dict so next threshold can trigger after protection window
    local marker_key = "blocked_marker:" .. ip .. ":" .. tostring(status)
    pcall(function() shm:delete(marker_key) end)
end

-- ==========================================
-- 主流程 (log_by_lua) - 嚴禁 cosocket / blocking I/O
-- ==========================================

-- 1. 取得實際狀態碼（優先 upstream_status）
local status
local upstream_status = ngx.var.upstream_status
if upstream_status and upstream_status ~= "" and upstream_status ~= "-" then
    status = upstream_status:match("^(%d+)")
else
    status = tostring(ngx.status)
end
if not status then return end

-- 2. 是否為關心的錯誤碼
local threshold = ERROR_THRESHOLDS[status]
if not threshold then return end

-- 3. 白名單快速檢查
local ip = ngx.var.remote_addr or "unknown"
if is_whitelisted(ip) then return end

-- 4. shared dict 計數（此處允許使用 ngx.shared）
local vhost = ngx.var.host or ngx.var.server_name or "unknown"
local shm_key = "error_count:" .. ip .. ":" .. status

local new_count, err = shm:incr(shm_key, 1)
if not new_count then
    -- set initial value and expiry
    shm:set(shm_key, 1, ERROR_WINDOW)
    new_count = 1
else
    -- ensure expiry exists
    pcall(function() shm:expire(shm_key, ERROR_WINDOW) end)
end

-- 5. 未達門檻則結束
if new_count < threshold then return end

-- 6. Thundering herd protection: 用 marker 防止短時間內多次排程
local marker_key = "blocked_marker:" .. ip .. ":" .. status
local marked = shm:get(marker_key)
if marked then return end

-- set marker (60s protection while timer runs)
shm:set(marker_key, 1, 60)

-- 7. 嘗試獲取 local geo (輕量)
local local_geo = get_local_geo_info()

-- 8. 在 timer 中非同步處理 ban / redis / notify
local ok, timer_err = ngx.timer.at(0, async_ban_process, ip, status, new_count, vhost, threshold, local_geo)
if not ok then
    ngx.log(ngx.ERR, "[log_error_block] failed to create timer: ", tostring(timer_err))
    -- 若 Timer 建立失敗，解除 marker 讓下一次請求重試
    pcall(function() shm:delete(marker_key) end)
end

-- end of log_by_lua handler
return

