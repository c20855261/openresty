-- log_error_block.lua
local shm = ngx.shared.error_block_dict
local redis = require "resty.redis"
local http = require "resty.http"
local telegram = require "telegram"
local geo = require "geo_mapping"
 
-- 設定參數
local ENABLE_NOTIFICATION = true
local BAN_TIME = 3600
 
local ERROR_THRESHOLDS = {
    [400] = 30,
    [401] = 20,
    [403] = 50,
    [404] = 60
}

local TIME_WINDOW = 120
local WHITELIST_FILE = "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"
local REDIS_HOST = "127.0.0.1"
local REDIS_PORT = 6379
 
-- 設為 true 僅發送通知，不封鎖；false 啟用封鎖
--local TEST_MODE = true
local TEST_MODE = false
 
-- 檢查白名單
local function is_whitelisted(ip)
    local file = io.open(WHITELIST_FILE, "r")
    if not file then
        ngx.log(ngx.ERR, "無法打開白名單檔案: ", WHITELIST_FILE)
        return false
    end
    local content = file:read("*a")
    file:close()
    return content:find("%f[%a%d]" .. ip .. "%f[^%a%d]") ~= nil
end
 
-- GeoIP 查詢
local function get_geo_info(ip, country_code, country_name_en, city_name_en)
    country_code = country_code or "Unknown"
    country_name_en = country_name_en or "Unknown"
    city_name_en = city_name_en or ""
 
    local country_name = geo.country_map[country_name_en] or country_name_en
    local city_name = ""
 
    -- 先用 MaxMindDB
    if city_name_en ~= "" and city_name_en ~= "Unknown" then
        city_name = geo.city_map[city_name_en] or city_name_en
    else
        -- MaxMindDB 無城市資訊，嘗試 API
        local httpc = http.new()
        httpc:set_timeout(2000)  -- 超時 2 秒
 
        local apis = {
            { host = "ip-api.com", ipv4 = "208.95.112.1", port = 80, path = "/json/" .. ip .. "?fields=city", field = "city", name = "ip-api.com" },
            { host = "freeipapi.com", ipv4 = "104.21.94.136", port = 80, path = "/api/json/" .. ip, field = "cityName", name = "freeipapi.com" }
        }
 
        for _, api in ipairs(apis) do
            local ok, err = httpc:connect(api.ipv4, api.port)
            if not ok then
                ngx.log(ngx.ERR, api.name .. " 連接失敗: ", err, " (IP: ", ip, ")")
            else
                local res, req_err = httpc:request({
                    path = api.path,
                    method = "GET",
                    headers = { ["Host"] = api.host },
                    ssl_verify = false
                })
                if res then
                    local json = require "cjson.safe"
                    local body = json.decode(res.body)
                    if body and body[api.field] and body[api.field] ~= "" then
                        city_name = geo.city_map[body[api.field]] or body[api.field]
                        break
                    end
                else
                    ngx.log(ngx.ERR, api.name .. " 請求失敗: ", req_err, " (IP: ", ip, ")")
                end
            end
        end
 
        if city_name == "" then
            city_name = "null"
        end
        httpc:close()
    end
 
    local location = city_name ~= "null" and (city_name .. ", ") or ""
    location = location .. country_name .. " (" .. country_code .. ")"
    return location
end
 
-- 異步通知與封鎖
local function async_notify_and_ban(premature, client_ip, status, ttl, count_key, test_mode, country_code, country_name_en, city_name_en, vhost, hostname, proxy_ip)
    if premature then return end
 
    -- 連接到 Redis
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        ngx.log(ngx.ERR, "Redis 連線失敗: ", err)
        return
    end
 
    -- 檢查是否已封鎖
    local ban_key = "ban:" .. client_ip
    if red:get(ban_key) == ngx.null then
        -- 執行 GeoIP 查詢
        local ip_location = get_geo_info(client_ip, country_code, country_name_en, city_name_en)
 
        -- 構建通知訊息
        local threshold = ERROR_THRESHOLDS[status]
        local message =
            "Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
            "\nHost: " .. (hostname or "unknown") ..
            "\nVhost: " .. (vhost or "unknown") ..
            "\nGetway_IP: " .. (proxy_ip or "unknown") ..
            "\nBlocked_IP: " .. client_ip ..
            "\nIP_Location: " .. ip_location ..
            "\nStatus: 錯誤碼 " .. status .. " 在 " .. TIME_WINDOW .. " 秒內超過 " .. threshold .. " 次"
 
        -- 發送通知
        telegram.send_once(client_ip, message, ttl)
 
        -- 非測試模式下設置封鎖
        if not test_mode then
            red:setex(ban_key, ttl, "1")
            if shm then
                shm:set(ban_key, 1, ttl)
            end
        end
    end
 
    -- 清理計數
    if not test_mode then
        red:del(count_key)
    end
    red:close()
end
 
-- 主邏輯
local status = tonumber(ngx.status)
local client_ip = ngx.var.remote_addr
 
if not ERROR_THRESHOLDS[status] then
    return
end
 
if is_whitelisted(client_ip) then
    if shm then
        shm:delete("error_count:" .. client_ip .. ":" .. status)
        shm:delete("ban:" .. client_ip)
    end
    return
end
 
local count_key = "error_count:" .. client_ip .. ":" .. status
local threshold = ERROR_THRESHOLDS[status]
local current_count = shm:get(count_key) or 0
current_count = current_count + 1
 
if shm then
    shm:set(count_key, current_count, TIME_WINDOW)
else
    ngx.log(ngx.ERR, "ngx.shared.error_block_dict 未定義，無法記錄錯誤計數")
    return
end
 
if current_count >= threshold then
    if ENABLE_NOTIFICATION then
        -- 在請求上下文中收集 GeoIP 變數
        local country_code = ngx.var.geoip2_data_country_code
        local country_name_en = ngx.var.geoip2_data_country_name
        local city_name_en = ngx.var.geoip2_data_city_name
        local vhost = ngx.var.host
        local hostname = io.popen("hostname"):read("*l")
        local proxy_ip = io.popen("curl -s ifconfig.me"):read("*l")
 
        local ok, err = ngx.timer.at(0, async_notify_and_ban, client_ip, status, BAN_TIME, count_key, TEST_MODE, country_code, country_name_en, city_name_en, vhost, hostname, proxy_ip)
        if not ok then
            ngx.log(ngx.ERR, "創建異步通知與封鎖 timer 失敗: ", err)
        end
    end
 
    if shm then
        shm:delete(count_key)
    end
end
