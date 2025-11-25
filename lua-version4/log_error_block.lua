local cfg = require "config"
local redis = require "resty.redis"
local telegram = require "telegram"
local http = require "resty.http"
local cjson = require "cjson.safe"

-- TEST_MODE: true = 只發通知 (no ban, no shared-dict clears, no daily updates)
--            false = 正常流程（設 ban、清 shared dict、更新 daily 統計）
local TEST_MODE = false

local shm = ngx.shared.error_block_dict
if not shm then
    ngx.log(ngx.ERR, "shared dict error_block_dict not defined")
    return
end

local REDIS_HOST = cfg.redis_host or "127.0.0.1"
local REDIS_PORT = cfg.redis_port or 6379
local BAN_TTL = cfg.ban_time or cfg.ban_ttl or 10800
local DAILY_TTL = cfg.daily_ttl or (60 * 60 * 24 * 14)  -- daily key 保留天數(預設14天)
local ERROR_WINDOW = cfg.error_window or 120           -- 監控窗口秒數

local ERROR_THRESHOLDS = cfg.error_thresholds or {
    ["400"] = 30,
    ["401"] = 20,
    ["403"] = 50,
    ["404"] = 80
}

local function redis_connect()
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil, err
    end
    return red, nil
end

local function get_geo_info(ip)
    -- 先試用本 repo 的 geo_mapping（期望有 country_map 對應英->中）
    local ok_geo, geo_mod = pcall(require, "geo_mapping")
    local country_code = nil
    local country_name_en = nil
    local city_name_en = nil

    -- 先嘗試 ip-api 以取得基本欄位（ip-api 快而且簡單）
    local httpc = http.new()
    httpc:set_timeout(1000)
    local res, err = httpc:request_uri("http://ip-api.com/json/" .. ngx.escape_uri(ip) .. "?fields=status,country,regionName,city,countryCode", { method = "GET" })
    if res and res.status == 200 and res.body then
        local j = cjson.decode(res.body)
        if j and j.status == "success" then
            country_name_en = j.country or ""
            city_name_en = j.city or ""
            country_code = j.countryCode or ""
        end
    end

    -- 若有 geo_mapping 且提供 country_map，嘗試找中文名稱
    local country_name_cn = nil
    if ok_geo and geo_mod and type(geo_mod.country_map) == "table" and country_name_en and country_name_en ~= "" then
        country_name_cn = geo_mod.country_map[country_name_en] or geo_mod.country_map[country_name_en:lower()]
    end

    -- 組合輸出
    if country_name_cn and country_name_cn ~= "" then
        -- 有中文名
        if city_name_en and city_name_en ~= "" then
            return country_name_cn .. "，" .. city_name_en .. " (" .. (country_code or "") .. ")"
        else
            return country_name_cn .. " (" .. (country_code or "") .. ")"
        end
    end

    if country_name_en and country_name_en ~= "" then
        if city_name_en and city_name_en ~= "" then
            return country_name_en .. ", " .. city_name_en .. " (" .. (country_code or "") .. ")"
        else
            return country_name_en .. " (" .. (country_code or "") .. ")"
        end
    end

    return "Unknown"
end

-- signature: premature, ip, status_code, detected_count, vhost, threshold
local function async_handle(premature, ip, status_code, detected_count, vhost, threshold)
    if premature then return end

    local geo = get_geo_info(ip)

    -- 取得 hostname 與 gateway ip（若無法取得就回傳 "unknown"）
    local hostname = "unknown"
    pcall(function()
        local fh = io.popen("hostname")
        if fh then
            local h = fh:read("*l")
            if h and h ~= "" then hostname = h end
            fh:close()
        end
    end)
    local gateway_ip = "unknown"
    pcall(function()
        local fh = io.popen("curl -s ifconfig.me")
        if fh then
            local gip = fh:read("*l")
            if gip and gip ~= "" then gateway_ip = gip end
            fh:close()
        end
    end)

    if TEST_MODE then
        local msg_test =
            "[TEST_MODE] Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
            "\nHost: " .. hostname ..
            "\nVhost: " .. (vhost or "unknown") ..
            "\nGetway_IP: " .. gateway_ip ..
            "\nBlocked_IP: " .. ip ..
            "\nIP_Location: " .. tostring(geo) ..
            "\nStatus: 錯誤碼 " .. tostring(status_code) .. " 在 " .. tostring(ERROR_WINDOW) .. " 秒內超過 " .. tostring(threshold or detected_count) .. " 次" ..
            "\nNOTE: TEST_MODE enabled - no ban set, no SHM/daily changes."
        pcall(function() telegram.send(msg_test) end)
        ngx.log(ngx.NOTICE, msg_test)
        return
    end

    local red, err = redis_connect()
    if not red then
        ngx.log(ngx.ERR, "log_error_block.lua async redis connect failed: ", err)
        -- 仍然發送通知（即使 Redis 連不上）
        local msg_no_redis =
            "Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
            "\nHost: " .. hostname ..
            "\nVhost: " .. (vhost or "unknown") ..
            "\nGetway_IP: " .. gateway_ip ..
            "\nBlocked_IP: " .. ip ..
            "\nIP_Location: " .. tostring(geo) ..
            "\nStatus: 錯誤碼 " .. tostring(status_code) .. " 在 " .. tostring(ERROR_WINDOW) .. " 秒內超過 " .. tostring(threshold or detected_count) .. " 次" ..
            "\nNote: Redis connect failed: " .. tostring(err)
        pcall(function() telegram.send(msg_no_redis) end)
        return
    end

    -- 設定 ban
    local ban_key = "ban:" .. ip
    local ok, err1 = red:setex(ban_key, BAN_TTL, "1")
    if not ok then
        ngx.log(ngx.ERR, "failed setex ban:", err1)
    else
        ngx.log(ngx.NOTICE, "set ban for ip=", ip, " ttl=", BAN_TTL)
    end

    -- 清除 shared dict 中該 IP 的錯誤計數（pattern）
    local okc, keylist = pcall(function() return ngx.shared.error_block_dict:get_keys(0) end)
    if okc and keylist then
        for _, k in ipairs(keylist) do
            if type(k) == "string" and k:match("^error_count:" .. ip .. ":") then
                ngx.shared.error_block_dict:delete(k)
            end
        end
    end

    local daily_key = "daily:ipcounts:" .. os.date("%Y%m%d")
    local member = tostring(vhost or "unknown") .. ":" .. tostring(ip)
    local ok2, err2 = red:zincrby(daily_key, 1, member)
    if not ok2 then
        ngx.log(ngx.ERR, "daily zincrby failed: ", err2)
    else
        -- 確保 TTL
        local ttl = red:ttl(daily_key)
        if ttl == ngx.null or ttl == -1 then
            pcall(function() red:expire(daily_key, DAILY_TTL) end)
        end
    end

    local msg =
        "Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
        "\nHost: " .. hostname ..
        "\nVhost: " .. (vhost or "unknown") ..
        "\nGetway_IP: " .. gateway_ip ..
        "\nBlocked_IP: " .. ip ..
        "\nIP_Location: " .. tostring(geo) ..
        "\nStatus: 錯誤碼 " .. tostring(status_code) .. " 在 " .. tostring(ERROR_WINDOW) .. " 秒內超過 " .. tostring(threshold or detected_count) .. " 次" ..
        "\nBan TTL(s): " .. tostring(BAN_TTL)

    pcall(function() telegram.send(msg) end)

    pcall(function() red:set_keepalive(10000, 100) end)
end

local status = tostring(ngx.status)
if not ERROR_THRESHOLDS[status] then
    return
end

-- 取得 client ip 與 host
local client_ip = ngx.var.remote_addr or ngx.var.http_x_forwarded_for or "unknown"
local vhost = ngx.var.host or ngx.var.server_name or "unknown"

-- SHM key: error_count:<ip>:<status>
local shm_key = "error_count:" .. client_ip .. ":" .. status

local new_count, err = shm:incr(shm_key, 1, 0)
if not new_count then
    ngx.log(ngx.ERR, "shm incr failed: ", err, " key=", shm_key)
    local succ, seterr = shm:set(shm_key, 1, ERROR_WINDOW)
    if not succ then
        ngx.log(ngx.ERR, "shm set fallback failed: ", seterr)
    end
    new_count = 1
else
    if new_count == 1 then
        if type(shm.expire) == "function" then
            local succ, seterr = pcall(function() return shm:expire(shm_key, ERROR_WINDOW) end)
            if not succ then
                -- 如果 expire 呼叫失敗，再使用 set 來覆蓋並設定 expiry
                local okset, oerr = shm:set(shm_key, 1, ERROR_WINDOW)
                if not okset then
                    ngx.log(ngx.ERR, "shm set expiry fallback failed: ", oerr)
                end
            end
        else
            -- 如沒有 expire 方法，使用 set 設定過期
            local okset, oerr = shm:set(shm_key, 1, ERROR_WINDOW)
            if not okset then
                ngx.log(ngx.ERR, "shm set expiry fallback failed: ", oerr)
            end
        end
    end
end

local threshold = ERROR_THRESHOLDS[status] or 999999
if new_count >= threshold then
    -- 防止重複頻繁產生 timer：在 shared dict 中寫一個短期標記 key "blocked_marker:<ip>:<status>"
    local marker_key = "blocked_marker:" .. client_ip .. ":" .. status
    local already = shm:get(marker_key)
    if not already then
        local succ, serr = shm:set(marker_key, 1, ERROR_WINDOW) -- 與窗口同時長，避免重複
        if not succ then
            ngx.log(ngx.ERR, "set marker failed: ", serr)
        end
        -- 傳入 threshold 給 timer callback 以便顯示在通知訊息中
        local ok, err = ngx.timer.at(0, async_handle, client_ip, tonumber(status), new_count, vhost, threshold)
        if not ok then
            ngx.log(ngx.ERR, "failed to create timer: ", err)
        end
    end
end

-- end of file
