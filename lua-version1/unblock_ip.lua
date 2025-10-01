-- /opt/openresty/nginx/conf/conf.d/lua/unblock_ip.lua
local shm = ngx.shared.error_block_dict
local redis = require "resty.redis"
local ip = ngx.var.arg_ip  -- 從查詢參數獲取 IP
local REDIS_HOST = "10.32.0.21"
local REDIS_PORT = 6379
 
if not ip then
    ngx.status = 400
    ngx.say("請提供 IP 參數，例如 ?ip=61.216.73.121")
    return
end
 
-- 清除 shm 中的 ban_key 和 error_count
if shm then
    shm:delete("ban:" .. ip)
    for _, key in ipairs(shm:get_keys()) do
        if key:match("^error_count:" .. ip .. ":") then
            shm:delete(key)
        end
    end
    ngx.log(ngx.NOTICE, "已從 shm 清除 IP: ", ip)
else
    ngx.log(ngx.ERR, "ngx.shared.error_block_dict 未定義")
    ngx.status = 500
    ngx.say("共享記憶體未定義")
    return
end
 
-- 清除 Redis 中的 ban_key 和 count
local red = redis:new()
red:set_timeout(1000)
local ok, err = red:connect(REDIS_HOST, REDIS_PORT)                                                                                 
if ok then
    red:del("ban:" .. ip)
    red:del("count:" .. ip)
    red:close()
    ngx.log(ngx.NOTICE, "已從 Redis 清除 IP: ", ip)
else
    ngx.log(ngx.ERR, "Redis 連線失敗: ", err)
    ngx.status = 500
    ngx.say("Redis 連線失敗")
    return
end
 
ngx.status = 200
ngx.say("IP " .. ip .. " 已解除封鎖")
