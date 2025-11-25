-- block_ip.lua
local redis = require "resty.redis"
local http = require "resty.http"
local telegram = require "telegram"
local geo = require "geo_mapping"
 
-- 設定參數
local ban_time = 3600
local max_requests = 1000
local time_window = 180
local whitelist_file = "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"
local REDIS_HOST = "127.0.0.1"
local REDIS_PORT = 6379
 
-- 設為 false 啟用正式封鎖
local TEST_MODE = false
 
local function get_geo_info(ip)
    local country_code = ngx.var.geoip2_data_country_code or "Unknown"
    local country_name_en = ngx.var.geoip2_data_country_name or "Unknown"
    local city_name_en = ngx.var.geoip2_data_city_name or ""
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
 
-- 獲取客戶端 IP
local client_ip = ngx.var.remote_addr
local count_key = "count:" .. client_ip
local ban_key = "ban:" .. client_ip
 
-- 檢查白名單
local function is_whitelisted(ip)
    local file = io.open(whitelist_file, "r")
    if not file then
        ngx.log(ngx.ERR, "無法打開白名單檔案: ", whitelist_file)
        return false
    end
    local content = file:read("*a")
    file:close()
    return content:find("%f[%a%d]" .. ip .. "%f[^%a%d]") ~= nil
end
 
-- 若為白名單 IP，則略過檢查並清除 Redis 中的計數紀錄
if is_whitelisted(client_ip) then
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if ok then
        red:del("count:" .. client_ip)
        red:del("ban:" .. client_ip)
        red:close()
    else
        ngx.log(ngx.ERR, "Redis 連線失敗（白名單清理）: ", err)
    end
    return
end
 
-- 連接到 Redis
local red = redis:new()
red:set_timeout(1000)
local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
if not ok then
    ngx.log(ngx.ERR, "Redis 連線失敗: ", err)
    return
end
 
-- 檢查是否已被封鎖
if red:get(ban_key) ~= ngx.null then
    red:close()
    ngx.exit(444)
end
 
-- 紀錄請求次數
local request_count = red:get(count_key)
request_count = request_count == ngx.null and 0 or tonumber(request_count)
local ttl = red:ttl(count_key)
 
-- 僅在接近閾值（80%）時記錄統計
--if request_count >= max_requests * 0.8 then
--    ngx.log(ngx.NOTICE, "IP: ", client_ip, ", 當前連線數接近閾值: ", request_count + 1, ", 剩餘TTL: ", ttl ~= ngx.null and ttl or time_window)
--end
 
-- 固定時間
local is_new = request_count == 0
red:incr(count_key)
if is_new then
    local ok, err = red:expire(count_key, time_window)
    if not ok then
        ngx.log(ngx.ERR, "首次設置計數過期失敗: ", err)
    end
end
 
-- 超過次數限制則發送通知
if request_count >= max_requests then
    -- 檢查是否已封鎖，避免重複通知
    if red:get(ban_key) == ngx.null then
        local ip_location = get_geo_info(client_ip)
 
        local vhost = ngx.var.host or ngx.var.server_name or "unknown"
        local hostname = io.popen("hostname"):read("*l") or "unknown"
        local proxy_ip = io.popen("curl -s ifconfig.me"):read("*l") or "unknown"
 
        local message =
            "Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
            "\nHost: " .. hostname ..
            "\nVhost: " .. vhost ..
            "\nGetway_IP: " .. proxy_ip ..
            "\nBlocked_IP: " .. client_ip ..
            "\nIP_Location: " .. ip_location ..
            "\nStatus: " .. time_window .. " 秒內連線超過 " .. max_requests .. " 次"
 
        telegram.send_once(client_ip, message, ban_time)
 
        if not TEST_MODE then
            red:setex(ban_key, ban_time, "1")
            red:del(count_key)
        end
    end
 
    red:close()
    if not TEST_MODE then
        ngx.exit(444)
    end
end
 
red:close()

