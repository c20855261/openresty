ngx.log(ngx.NOTICE, "[TEST] 防禦 Lua 腳本已執行")
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
  
-- 測試模式開關
-- local TEST_MODE = true  -- 設為 false 啟用正式封鎖
local TEST_MODE = false
  
  
local function get_geo_info(ip)
    local country_code    = ngx.var.geoip2_data_country_code or "Unknown"
    local country_name_en = ngx.var.geoip2_data_country_name or "Unknown"
    local city_name_en    = ngx.var.geoip2_data_city_name    or ""
  
        -- ★ 改用外部 table
    local country_name = geo.country_map[country_name_en] or country_name_en
    local city_name    = ""
  
    -- 先用 MaxMindDB
    if city_name_en ~= "" and city_name_en ~= "Unknown" then
        city_name = geo.city_map[city_name_en] or city_name_en
    else
        -- MaxMindDB 沒有，再用 ip-api.com 查詢
        local httpc = http.new()
        local res, err = httpc:request_uri("http://ip-api.com/json/" .. ip .. "?fields=city", {
            method = "GET",
            ssl_verify = false,
            timeout = 1000,
        })
        if not res then
            ngx.log(ngx.ERR, "ip-api.com 查詢失敗: ", err)
            city_name = "null"
        else
            local json = require "cjson.safe"
            local body = json.decode(res.body)
            if body and body.city and body.city ~= "" then
                city_name = geo.city_map[body.city] or body.city
            else
                city_name = "null"
            end
        end
    end
  
    local location = city_name ~= "" and (city_name .. ", ") or ""
    location = location .. country_name .. " (" .. country_code .. ")"
  
    ngx.log(ngx.NOTICE, "GeoIP Debug - IP:", ip, ", Location:", location)
    return location
    end
  
-- local city_name_en    = ngx.var.geoip2_data_city_name or ""
-- ngx.log(ngx.NOTICE, "[GI] city_name_en=", city_name_en,
--   ", subdivision=", ngx.var.geoip2_data_subdivision_name or "")
--                  ", subdivision=", ngx.var.geoip2_data_subdivision_name or "")
  
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
    ngx.log(ngx.NOTICE, "IP 在白名單: ", client_ip)
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
  
-- 連接到 Redis（非白名單 IP 才會執行到這裡）
local red = redis:new()
red:set_timeout(1000)
local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
if not ok then
    ngx.log(ngx.ERR, "Redis 連線失敗: ", err)
    return
end
  
-- 檢查是否已被封鎖
if red:get(ban_key) ~= ngx.null then
    ngx.log(ngx.NOTICE, "IP 已封鎖: ", client_ip)
    red:close()
    ngx.exit(444)
end
  
-- 紀錄請求次數
local request_count = red:get(count_key)
request_count = request_count == ngx.null and 0 or tonumber(request_count)
local ttl = red:ttl(count_key)
  
if ttl ~= ngx.null and ttl <= 5 then
    ngx.log(ngx.NOTICE, "IP: ", client_ip, ", 分鐘連線總數: ", request_count + 1, ", 即將重置")
end
ngx.log(ngx.NOTICE, "IP: ", client_ip, ", 當前連線數: ", request_count + 1, ", 剩餘TTL: ", ttl ~= ngx.null and ttl or time_window)
  
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
    ngx.log(ngx.NOTICE, "IP: ", client_ip, ", 超過限制，發送通知")
  
    -- 獲取 GeoIP2 資訊（已轉換為中文）
    local ip_location = get_geo_info(client_ip)
  
    local vhost = ngx.var.host or ngx.var.server_name or "unknown"
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
  
    ngx.log(ngx.NOTICE, "[DEBUG] Telegram message:\n", message)
    telegram.send_once(client_ip, message, ban_time)
  
    if not TEST_MODE then
        -- 正式環境：封鎖並清除計數
        ngx.log(ngx.NOTICE, "正式模式：封鎖IP並清除計數")
        red:setex(ban_key, ban_time, "1")
        red:del(count_key)
        red:close()
        ngx.exit(444)
    else
        -- 測試模式：保留計數器，不封鎖
        ngx.log(ngx.NOTICE, "測試模式：保留計數器，不封鎖IP")
        -- red:del(count_key)
        -- 不刪除計數器，讓它自然過期
        -- 也不封鎖IP，繼續正常處理請求
    end
end
  
red:close()

