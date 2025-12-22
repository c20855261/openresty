local http = require "resty.http"
local redis = require "resty.redis"
 
local telegram = {}
 
telegram.BOT_TOKEN = "your_tg_token"
telegram.CHAT_ID = "-your_tg_id"
 
function telegram.send(text)
    local httpc = http.new()
    httpc:set_timeout(2000)
 
    -- text = text:gsub("[^\x20-\x7E\n]", "")
    text = text:gsub("[\1-\9\11-\31]", "")
    if text == "" then
        ngx.log(ngx.ERR, "Telegram 訊息為空")
        ngx.log(ngx.NOTICE, "[DEBUG] Telegram Text:\n" .. text)
        httpc:close()
        return
    end
 
    local res, err = httpc:request_uri("https://api.telegram.org/bot" .. telegram.BOT_TOKEN .. "/sendMessage", {
        method = "POST",
        ssl_verify = false,
        body = "chat_id=" .. telegram.CHAT_ID .. "&text=" .. text,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
    })
 
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "Telegram 發送失敗: ", err or res.body)
    else
        ngx.log(ngx.NOTICE, "Telegram 發送成功")
    end
 
    httpc:close()
end
 
function telegram.send_once(ip, message, ttl)
    local notify_key = "notify:" .. ip
    local red = redis:new()
    red:set_timeout(1000)
 
    if not red:connect("10.32.0.21", 6379) then
        ngx.log(ngx.ERR, "Redis 連線失敗")
        red:close()
        return
    end
 
    local result = red:eval([[
        if redis.call('EXISTS', KEYS[1]) == 1 then return 0 end
        redis.call('SETEX', KEYS[1], ARGV[1], '1')
        return 1
    ]], 1, notify_key, ttl or 60)
 
    if not result then
        ngx.log(ngx.ERR, "Redis Lua 腳本失敗")
        red:close()
        return
    end
 
    if result == 0 then
        ngx.log(ngx.NOTICE, "IP: ", ip, ", 已發送通知，跳過")
        red:close()
        return
    end
 
    telegram.send(message)
    ngx.log(ngx.NOTICE, "IP: ", ip, ", 發送通知")
    red:close()
end
 
return telegram
