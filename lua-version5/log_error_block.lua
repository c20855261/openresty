local cfg = require "config"
local redis = require "resty.redis"
local telegram = require "telegram"
local geo = require "geo_mapping"
local http = require "resty.http"
local cjson = require "cjson.safe"

local TEST_MODE = false

local shm = ngx.shared.error_block_dict
if not shm then
    ngx.log(ngx.ERR, "[log_error_block] shared dict error_block_dict not defined")
    return
end

-- === 設定 ===
local REDIS_HOST = cfg.redis_host or "10.32.0.21"
local REDIS_PORT = cfg.redis_port or 6379
local BAN_TTL = cfg.ban_time or 10800
local ERROR_WINDOW = cfg.error_window or 120
local DAILY_KEY_TTL_SECONDS = 86400 + 3600  -- 25 hours
local WHITELIST_FILE = "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"

local ERROR_THRESHOLDS = cfg.error_thresholds or {
    ["400"] = 30,
    ["401"] = 20,
    ["403"] = 50,
    ["404"] = 80
}

-- === 白名單檢查（新增）===
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

-- === Redis helper ===
local function redis_connect()
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil, err
    end
    return red
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
        ngx.log(ngx.WARN, "[log_error_block] geo API failed: ", err or "status " .. (res and res.status or "nil"))
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

-- === 非同步 handler ===
local function async_handle(premature, ip, status, count, vhost, threshold, geo_info)
    if premature then
        return
    end

    -- ✅ 在非同步 handler 中也檢查白名單
    if is_whitelisted(ip) then
        ngx.log(ngx.NOTICE, "[log_error_block] IP ", ip, " is whitelisted, skip ban")
        return
    end

    local red, err = redis_connect()
    if not red then
        ngx.log(ngx.ERR, "[log_error_block] redis connect failed: ", err)
        return
    end

    local ban_key = "ban:" .. ip
    local notify_key = "notify:ban:" .. ip

    -- 檢查是否已被 ban
    local banned = red:get(ban_key)
    local already_banned = banned and banned ~= ngx.null

    -- 已 ban：不再通知、不重複 set
    if already_banned then
        red:set_keepalive(10000, 100)
        return
    end

    -- 嘗試設置 ban（只允許一次）
    local ok = red:setnx(ban_key, "ip")
    if ok ~= 1 then
        red:set_keepalive(10000, 100)
        return
    end

    red:expire(ban_key, BAN_TTL)

    -- ===== 每日統計 =====
    local date = os.date("%Y%m%d")
    local daily_key = "daily:" .. date .. ":" .. ip
    local data = red:get(daily_key)
    
    local stats = cjson.decode(data) or {
        ip = ip,
        geo = geo_info,
        conn_ban = 0,
        error_ban = 0,
        last_ban = ""
    }
    
    stats.error_ban = stats.error_ban + 1
    stats.last_ban = os.date("%Y-%m-%d %H:%M:%S")
    
    red:set(daily_key, cjson.encode(stats))
    red:expire(daily_key, DAILY_KEY_TTL_SECONDS)

    -- ===== Telegram 通知（僅第一次）=====
    local notify_ok = red:setnx(notify_key, "1")
    if notify_ok == 1 then
        red:expire(notify_key, BAN_TTL)

        local hostname = "unknown"
        pcall(function()
            local handle = io.popen("hostname")
            if handle then
                hostname = handle:read("*l") or hostname
                handle:close()
            end
        end)

        local gateway_ip = "unknown"
        pcall(function()
            local handle = io.popen("curl -s ifconfig.me")
            if handle then
                gateway_ip = handle:read("*l") or gateway_ip
                handle:close()
            end
        end)

        local msg =
            "Time: " .. stats.last_ban ..
            "\nHost: " .. hostname ..
            "\nVhost: " .. vhost ..
            "\nGateway_IP: " .. gateway_ip ..
            "\nBlocked_IP: " .. ip ..
            "\nIP_Location: " .. geo_info ..
            "\nStatus: " .. status ..
            "\nCount: " .. count .. " / " .. threshold ..
            "\nBan_TTL: " .. BAN_TTL .. "s"

        if not TEST_MODE then
            pcall(telegram.send, msg)
        else
            ngx.log(ngx.NOTICE, "[TEST_MODE] " .. msg)
        end
    end

    red:set_keepalive(10000, 100)
end

-- =========================
-- main (log_by_lua)
-- =========================

-- ✅ 優先使用 upstream 狀態碼
local status
local upstream_status = ngx.var.upstream_status

if upstream_status and upstream_status ~= "" and upstream_status ~= "-" then
    -- upstream_status 可能是 "404" 或 "404 : 302" 格式
    -- 取第一個狀態碼
    status = upstream_status:match("^(%d+)")
else
    -- 沒有 upstream 時使用 ngx.status
    status = tostring(ngx.status)
end

local threshold = ERROR_THRESHOLDS[status]
if not threshold then
    return
end

local ip = ngx.var.remote_addr or "unknown"

-- ✅ 白名單 IP 不計數、不封鎖
if is_whitelisted(ip) then
    return
end

local vhost = ngx.var.host or ngx.var.server_name or "unknown"

local shm_key = "error_count:" .. ip .. ":" .. status

-- 原子遞增
local new_count, err = shm:incr(shm_key, 1, 0)
if not new_count then
    ngx.log(ngx.ERR, "[log_error_block] shm incr failed: ", err)
    shm:set(shm_key, 1, ERROR_WINDOW)
    new_count = 1
elseif new_count == 1 then
    shm:expire(shm_key, ERROR_WINDOW)
end

-- 達標才進入後續流程
if new_count < threshold then
    return
end

-- 防止 timer 洗爆
local marker_key = "blocked_marker:" .. ip .. ":" .. status
local marked = shm:get(marker_key)
if marked then
    return
end

shm:set(marker_key, 1, ERROR_WINDOW)

-- ✅ 在請求上下文中先取得 geo 資訊
local geo_info = get_geo_info(ip)

local ok, terr = ngx.timer.at(
    0,
    async_handle,
    ip,
    status,
    new_count,
    vhost,
    threshold,
    geo_info  -- ✅ 傳入 geo_info
)

if not ok then
    ngx.log(ngx.ERR, "[log_error_block] timer create failed: ", terr)
end
