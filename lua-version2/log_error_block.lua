-- log_error_block.lua (v5 修正版 + TEST_MODE 支援)
-- 修正與新增：
--  - 新增 TEST_MODE 開關：設為 true 僅發送通知，不在 Redis 設 ban、也不修改 shared dict / daily 統計（避免破壞性操作）
--  - 保留當 threshold 觸發時的非同步處理與 Telegram 通知
--  - 先前已修正的 "function arguments expected near 'and'" 問題保留
-- 使用路徑: /opt/openresty/nginx/conf/conf.d/lua/log_error_block.lua
-- 在 nginx.conf 中使用:
--   lua_shared_dict error_block_dict 10m;
--   log_by_lua_file /opt/openresty/nginx/conf/conf.d/lua/log_error_block.lua;
--
local cfg = require "config"         -- 需在 lua/config.lua 定義 redis_host, redis_port, ban_time 等
local redis = require "resty.redis"
local telegram = require "telegram" -- repo 內已有 telegram 模組
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

-- 配置（以 config 為主，否則使用預設值）
local REDIS_HOST = cfg.redis_host or "10.32.0.21"
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

-- helper: 開 Redis 連線
local function redis_connect()
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil, err
    end
    return red, nil
end

-- helper: 取得 geo info（使用現有 geo_mapping 模組或 ip-api）
local function get_geo_info(ip)
    local ok, geo_mod = pcall(require, "geo_mapping")
    -- 若 geo_mapping 可用且提供方法，可在此使用；目前 fallback 為 ip-api
    local httpc = http.new()
    httpc:set_timeout(1000)
    local res, err = httpc:request_uri("http://ip-api.com/json/" .. ngx.escape_uri(ip) .. "?fields=status,country,regionName,city,countryCode", { method = "GET" })
    if not res or res.status ~= 200 or not res.body then
        return "Unknown"
    end
    local j = cjson.decode(res.body)
    if not j or j.status ~= "success" then
        return "Unknown"
    end
    local parts = {}
    if j.country then table.insert(parts, j.country) end
    if j.regionName and j.regionName ~= "" then table.insert(parts, j.regionName) end
    if j.city and j.city ~= "" then table.insert(parts, j.city) end
    if j.countryCode then table.insert(parts, "(" .. j.countryCode .. ")") end
    return table.concat(parts, ", ")
end

-- 非同步處理（timer callback）
-- note: 在 TEST_MODE 下，此 callback 只發送通知與日誌，不對 Redis/shm 做破壞性操作
local function async_handle(premature, ip, status_code, detected_count, vhost)
    if premature then return end

    local geo = get_geo_info(ip)

    -- 如果是測試模式，只發通知，不設 ban、不清 SHM、不寫 daily 統計
    if TEST_MODE then
        local msg_test =
            "[TEST_MODE] Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
            "\nVhost: " .. (vhost or "unknown") ..
            "\nDetected IP: " .. ip ..
            "\nStatus: HTTP " .. tostring(status_code) ..
            "\nCount: " .. tostring(detected_count) ..
            "\nLocation: " .. tostring(geo) ..
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
            "\nVhost: " .. (vhost or "unknown") ..
            "\nBlocked IP: " .. ip ..
            "\nStatus: HTTP " .. tostring(status_code) ..
            "\nCount: " .. tostring(detected_count) ..
            "\nLocation: " .. tostring(geo) ..
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

    -- 在 daily 統計加入一筆（member = vhost:ip）
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

    -- 發送通知 (Telegram)
    local msg =
        "Time: " .. os.date("%Y-%m-%d %H:%M:%S") ..
        "\nVhost: " .. (vhost or "unknown") ..
        "\nBlocked IP: " .. ip ..
        "\nStatus: HTTP " .. tostring(status_code) ..
        "\nCount: " .. tostring(detected_count) ..
        "\nLocation: " .. tostring(geo) ..
        "\nBan TTL(s): " .. tostring(BAN_TTL)

    pcall(function() telegram.send(msg) end)

    pcall(function() red:set_keepalive(10000, 100) end)
end

-- main (執行於 log_by_lua)
local status = tostring(ngx.status)
-- 只處理感興趣的錯誤碼
if not ERROR_THRESHOLDS[status] then
    return
end

-- 取得 client ip 與 host
local client_ip = ngx.var.remote_addr or ngx.var.http_x_forwarded_for or "unknown"
local vhost = ngx.var.host or ngx.var.server_name or "unknown"

-- SHM key: error_count:<ip>:<status>
local shm_key = "error_count:" .. client_ip .. ":" .. status

-- 原子遞增 shared dict 中的錯誤次數
local new_count, err = shm:incr(shm_key, 1, 0)
if not new_count then
    ngx.log(ngx.ERR, "shm incr failed: ", err, " key=", shm_key)
    -- 如果 incr 失敗，嘗試 set（並帶 expiry）
    local succ, seterr = shm:set(shm_key, 1, ERROR_WINDOW)
    if not succ then
        ngx.log(ngx.ERR, "shm set fallback failed: ", seterr)
    end
    new_count = 1
else
    -- 若為新鍵(=1)時，設 expiry（先檢查是否有 expire 方法）
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

-- 若超過閾值，使用 timer 非同步執行 Redis 與通知相關工作（避免在 log 階段阻塞）
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
        local ok, err = ngx.timer.at(0, async_handle, client_ip, tonumber(status), new_count, vhost)
        if not ok then
            ngx.log(ngx.ERR, "failed to create timer: ", err)
        end
    end
end

-- end of file
