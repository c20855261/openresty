local redis = require "resty.redis"
local http = require "resty.http"
local telegram = require "telegram"
local geo = require "geo_mapping"
local cjson = require "cjson.safe"

local cfg = require "config"
local ban_time = cfg.ban_time or 10800
local max_requests = 2000
local time_window = 60
local whitelist_file = "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"
local REDIS_HOST = "127.0.0.1"
local REDIS_PORT = 6379
local DAILY_KEY_TTL_SECONDS = 60 * 60 * 24 * 30  -- 保留 30 天

local TEST_MODE = false

local function get_geo_info(ip)
    local country_code = ngx.var.geoip2_data_country_code or "Unknown"
    local country_name_en = ngx.var.geoip2_data_country_name or "Unknown"
    local city_name_en = ngx.var.geoip2_data_city_name or ""
    local country_name = geo.country_map[country_name_en] or country_name_en
    local city_name = ""
    if city_name_en and city_name_en ~= "" then
        city_name = "，" .. city_name_en
    end
    return country_name .. city_name .. " (" .. country_code .. ")"
end

local function is_whitelisted(ip)
    local f = io.open(whitelist_file, "r")
    if not f then
        return false
    end
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

local function daily_key_for_time(ts)
    ts = ts or ngx.time()
    return "daily:ipcounts:" .. os.date("%Y%m%d", ts)
end

local function incr_daily_ip_count(red, vhost, ip)
    local key = daily_key_for_time()
    local member = tostring(vhost) .. ":" .. tostring(ip)
    local ok, err = red:zincrby(key, 1, member)
    if not ok then
        ngx.log(ngx.ERR, "daily zincrby 失敗: ", err, " key=", key, " member=", member)
        return
    end
    local ttl, err2 = red:ttl(key)
    if ttl == ngx.null or ttl == -1 or ttl == -2 then
        local ok2, err3 = red:expire(key, DAILY_KEY_TTL_SECONDS)
        if not ok2 then
            ngx.log(ngx.ERR, "設定 daily key ttl 失敗: ", err3, " key=", key)
        end
    end
end

-- 主流程
ngx.log(ngx.NOTICE, "[INFO] block_ip.lua 執行")
local client_ip = ngx.var.remote_addr or ngx.var.http_x_forwarded_for or "unknown"
local vhost = ngx.var.host or ngx.var.server_name or "unknown"

-- 白名單
if is_whitelisted(client_ip) then
    ngx.log(ngx.NOTICE, "白名單 IP，跳過封鎖：", client_ip)
    return
end

local red = redis:new()
red:set_timeout(1000)
local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
if not ok then
    ngx.log(ngx.ERR, "Redis 連線失敗: ", err)
    return
end

local count_key = "count:" .. vhost .. ":" .. client_ip
local ban_key = "ban:" .. client_ip

-- 如果已被封鎖，直接退出（與舊行為一致）
local is_banned, err = red:get(ban_key)
if is_banned and is_banned ~= ngx.null then
    ngx.log(ngx.NOTICE, "IP 已封鎖: ", client_ip)
    red:set_keepalive(10000, 100)
    ngx.exit(444)
end

local request_count = red:get(count_key)
request_count = request_count == ngx.null and 0 or tonumber(request_count)
local ttl = red:ttl(count_key)

local ok_incr, err_incr = pcall(incr_daily_ip_count, red, vhost, client_ip)
if not ok_incr then
    ngx.log(ngx.ERR, "incr_daily_ip_count 執行失敗: ", err_incr)
end

local is_new = request_count == 0
local _, err_incr2 = red:incr(count_key)
if err_incr2 then
    ngx.log(ngx.ERR, "redis incr 計數失敗: ", err_incr2)
end
if is_new then
    local okexp, er = red:expire(count_key, time_window)
    if not okexp then
        ngx.log(ngx.ERR, "首次設置計數過期失敗: ", er)
    end
end

if request_count >= max_requests then
    ngx.log(ngx.NOTICE, "IP: ", client_ip, ", 超過限制，發送通知")
    local ip_location = get_geo_info(client_ip)
    local hostname = io.popen("hostname"):read("*l") or "unknown"
    local proxy_ip = io.popen("curl -s ifconfig.me"):read("*l") or "unknown"

    local message =
        "Time：" .. os.date("%Y-%m-%d %H:%M:%S") ..
        "\nHost：" .. hostname ..
        "\nVhost：" .. vhost ..
        "\nGetway_IP：" .. proxy_ip ..
        "\nBlocked_IP：" .. client_ip ..
        "\nIP_Location：" .. ip_location ..
        "\nStatus：" .. time_window .. " 秒內連線超過 " .. max_requests .. " 次"

    if not TEST_MODE then
        local okset, errset = red:setex(ban_key, ban_time, "1")
        if not okset then
            ngx.log(ngx.ERR, "設定 ban_key 失敗: ", errset)
        end
        red:del(count_key)
    else
        ngx.log(ngx.NOTICE, "[TEST_MODE] 模擬封鎖：" .. client_ip)
    end

    pcall(telegram.send, message)
    red:set_keepalive(10000, 100)
    ngx.exit(444)
end

red:set_keepalive(10000, 100)
-- end
