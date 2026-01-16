local redis = require "resty.redis"
local cjson = require "cjson.safe"
local telegram = require "telegram"
local geo = require "geo_mapping"
local http = require "resty.http"
local cfg = require "config"

-- ========================
-- 設定
-- ========================
local REDIS_HOST = cfg.redis_host
local REDIS_PORT = cfg.redis_port
local BAN_TTL = cfg.ban_time or 10800
local MAX_REQUESTS = cfg.max_requests or 2000
local TIME_WINDOW = cfg.time_window or 60
local DAILY_KEY_TTL_SECONDS = 86400 + 3600  -- 25 hours
local WHITELIST_FILE = "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"
local TEST_MODE = false

-- ========================
-- 工具函式
-- ========================
local function is_whitelisted(ip)
    local f = io.open(WHITELIST_FILE, "r")
    if not f then return false end
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") and line == ip then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

-- === Geo helper（先查本地 geo_mapping，再查 API）===
local function get_geo_info(ip)
    -- 優先使用 ngx.var 的 GeoIP2 資訊
    local country = ngx.var.geoip2_data_country_name
    local city = ngx.var.geoip2_data_city_name or ""
    local code = ngx.var.geoip2_data_country_code or ""
    
    -- 如果本地有資料且不是 Unknown
    if country and country ~= "" and country ~= "Unknown" then
        local cname = geo.country_map[country] or country
        return cname .. (city ~= "" and ("，" .. city) or "") .. " (" .. code .. ")"
    end

    -- Fallback: 使用 API 查詢
    local httpc = http.new()
    httpc:set_timeout(1000)

    local res, err = httpc:request_uri(
        "http://ip-api.com/json/" .. ngx.escape_uri(ip) ..
        "?fields=status,country,city,countryCode",
        { method = "GET" }
    )

    if not res or res.status ~= 200 then
        ngx.log(ngx.WARN, "[block_ip] geo API failed: ", err or "status " .. (res and res.status or "nil"))
        return "Unknown"
    end

    local j = cjson.decode(res.body)
    if not j or j.status ~= "success" then
        return "Unknown"
    end

    local api_country = j.country or "Unknown"
    local api_cname = geo.country_map[api_country] or api_country
    
    return string.format(
        "%s，%s (%s)",
        api_cname,
        j.city or "",
        j.countryCode or ""
    )
end

-- ========================
-- 主流程
-- ========================
local client_ip = ngx.var.remote_addr

-- ✅ 優先檢查：無效 IP 或白名單直接放行
if not client_ip or is_whitelisted(client_ip) then
    return
end

local vhost = ngx.var.host or ngx.var.server_name or "unknown"

local red = redis:new()
red:set_timeout(1000)
local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
if not ok then
    ngx.log(ngx.ERR, "[block_ip] redis connect failed: ", err)
    return
end

-- ========================
-- ban key 優先（可能來自 log_error_block.lua）
-- ========================
local ban_key = "ban:" .. client_ip
local banned = red:get(ban_key)
if banned and banned ~= ngx.null then
    red:set_keepalive(10000, 100)
    return ngx.exit(444)
end

-- ========================
-- 連線計數
-- ========================
local count_key = "count:" .. vhost .. ":" .. client_ip
local current = tonumber(red:get(count_key)) or 0
local new_count = red:incr(count_key)
if current == 0 then
    red:expire(count_key, TIME_WINDOW)
end

-- ========================
-- 超過門檻 → ban
-- ========================
if new_count >= MAX_REQUESTS then
    -- 嘗試設置 ban（只允許一次）
    if red:setnx(ban_key, "1") == 1 then
        red:expire(ban_key, BAN_TTL)
        
        -- ===== 每日統計 =====
        local date = os.date("%Y%m%d")
        local daily_key = "daily:" .. date .. ":" .. client_ip
        local data = red:get(daily_key)
        local geo_info = get_geo_info(client_ip)
        
        local stats = cjson.decode(data) or {
            ip = client_ip,
            geo = geo_info,
            conn_ban = 0,
            error_ban = 0,
            last_ban = ""
        }
        
        stats.conn_ban = stats.conn_ban + 1
        stats.last_ban = os.date("%Y-%m-%d %H:%M:%S")
        
        red:set(daily_key, cjson.encode(stats))
        red:expire(daily_key, DAILY_KEY_TTL_SECONDS)
        
        -- ===== Telegram 通知（僅第一次）=====
        --local notify_key = "notify:ban:" .. client_ip
        local notify_key = "notify:ban:" .. ip
        if red:setnx(notify_key, "1") == 1 then
            red:expire(notify_key, BAN_TTL)
            
            local msg =
                "Time: " .. stats.last_ban ..
                "\nVhost: " .. vhost ..
                "\nIP: " .. client_ip ..
                "\nLocation: " .. geo_info ..
                "\nCount: " .. new_count .. "/" .. TIME_WINDOW .. "s" ..
                "\nBan_TTL: " .. BAN_TTL .. "s"
            
            if not TEST_MODE then
                pcall(telegram.send, msg)
            else
                ngx.log(ngx.NOTICE, "[TEST_MODE] " .. msg)
            end
        end
    end
    
    red:del(count_key)
    red:set_keepalive(10000, 100)
    return ngx.exit(444)
end

red:set_keepalive(10000, 100)
