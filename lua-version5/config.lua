-- 共用設定檔，用來統一 ban 時間等參數
-- 放在 lua/config.lua，供 block_ip.lua / daily_ip_stats.lua require 使用

local M = {}

-- 將 ban 時間統一設定在這（秒）
M.ban_time = 10800

-- daily_ip_stats 使用的黑名單 TTL（預設與 ban_time 相同）
M.ban_ttl = M.ban_time

-- Redis 主機設定（如需變更請調整）
M.redis_host = "10.32.0.21"
M.redis_port = 6379

-- secondary redis（可選，用於與舊檔案不一致的情況）
M.secondary_redis_host = "127.0.0.1"
M.secondary_redis_port = 6379

-- 白名單檔案路徑（可調）
M.whitelist_file = "/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt"

return M
