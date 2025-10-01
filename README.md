IP 封鎖與錯誤監控系統
這是一個基於 OpenResty 的 IP 封鎖與錯誤監控系統，搭配 Redis 實現請求頻率限制與 HTTP 錯誤碼封鎖，並通過 Telegram 發送通知。以下是專案結構、配置說明、手動清除 Nginx 共享記憶體（SHM）方法及範例。
專案結構
.
├── lua
│   ├── block_ip.lua          # 檢查請求頻率，超過閾值封鎖 IP
│   ├── geo_mapping.lua       # GeoIP 城市與國家名稱映射
│   ├── list_count.sh         # 列出 Redis 計數與封鎖記錄
│   ├── log_error_block.lua   # 監控 HTTP 錯誤碼，超過閾值封鎖
│   ├── telegram.lua          # Telegram 通知模組
│   ├── unblock_ip.lua        # 手動解除 IP 封鎖
│   └── whitelist.txt         # 白名單 IP 列表
├── lua-version1
│   ├── 00-befor
│   │   ├── block_ip.lua.b1   # block_ip.lua 舊版備份 1
│   │   └── block_ip.lua.b2   # block_ip.lua 舊版備份 2
│   ├── block_ip.lua          # 僅限次數封鎖的舊版
│   ├── geo_mapping.lua       # GeoIP 映射（同 lua 目錄）
│   ├── list_count.sh         # Redis 計數腳本（同 lua 目錄）
│   ├── telegram.lua          # Telegram 模組（同 lua 目錄）
│   └── whitelist.txt         # 白名單（同 lua 目錄）
└── README.md                 # 本文件

功能概述

請求頻率封鎖 (block_ip.lua)：

檢查 IP 請求次數（Redis count:<ip>），180 秒內超過 1000 次，設置 ban:<ip>（3600 秒），返回 HTTP 444。
白名單 IP 跳過檢查，清除 Redis 記錄。
發送 Telegram 通知，包含 IP 位置（MaxMindDB 或 API 查詢）。


HTTP 錯誤碼封鎖 (log_error_block.lua)：

監控錯誤碼（400、401、403、404），120 秒內超過閾值（30、20、50、60 次），設置 ban:<ip>（3600 秒）。
使用 ngx.shared.error_block_dict 計數，ngx.timer.at 異步寫入 Redis。
發送 Telegram 通知，包含錯誤詳情與 IP 位置。


GeoIP 查詢：

優先使用 MaxMindDB，若無城市資訊，查詢 ip-api.com 或 freeipapi.com。
結果格式：城市, 國家 (國家碼)（例如 "Hong Kong, 香港 (HK)"）。


白名單 (whitelist.txt)：

儲存允許 IP，跳過封鎖與計數。


解除封鎖 (unblock_ip.lua)：

手動清除指定 IP 的 Redis（ban:<ip>、count:<ip>）與 SHM（ban:<ip>、error_count:<ip>:*）記錄。


版本 1 (lua-version1)：

僅實現次數封鎖，無錯誤碼監控功能。



環境需求

OpenResty：支援 resty.redis 和 resty.http 模組。
Redis：運行於 127.0.0.1:6379（block_ip.lua、log_error_block.lua）或 10.32.0.21:6379（unblock_ip.lua），儲存計數與封鎖記錄。
MaxMindDB：提供 GeoIP 查詢（選用）。
Telegram Bot：用於通知（需配置 telegram.lua）。

Nginx 配置
在 /opt/openresty/nginx/conf/nginx.conf 的 http 塊中添加以下配置：
resolver 100.100.2.138 ipv6=off; # 名稱解析配置

lua_package_path "/opt/openresty/nginx/conf/conf.d/lua/?.lua;;";
lua_package_cpath "/opt/openresty/lualib/?.so;;";

lua_shared_dict error_block_dict 10m; # 共享記憶體

access_by_lua_file /opt/openresty/nginx/conf/conf.d/lua/block_ip.lua;
log_by_lua_file /opt/openresty/nginx/conf/conf.d/lua/log_error_block.lua;

# 解除封鎖端點
location /unblock_ip {
    content_by_lua_file /opt/openresty/nginx/conf/conf.d/lua/unblock_ip.lua;
}

功能詳解
1. 請求頻率封鎖

觸發條件：180 秒內請求超過 1000 次。
動作：設置 Redis ban:<ip>（3600 秒），返回 444。
通知：通過 Telegram 發送 IP 資訊（時間、主機、vhost、IP 位置）。
實現：block_ip.lua 使用 resty.redis 計數，resty.http 查詢 GeoIP。

2. HTTP 錯誤碼封鎖

觸發條件：120 秒內錯誤碼超過閾值（400: 30 次、401: 20 次、403: 50 次、404: 60 次）。
動作：設置 Redis ban:<ip>（3600 秒），清除計數。
通知：異步發送 Telegram 通知，包含錯誤詳情。
實現：log_error_block.lua 使用 ngx.shared.error_block_dict 計數，ngx.timer.at 寫入 Redis。

3. 白名單

檔案：/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt。
功能：白名單 IP 跳過封鎖，清除 Redis 和 SHM 記錄。

4. 手動解除封鎖

檔案：unblock_ip.lua。
功能：清除指定 IP 的 Redis（ban:<ip>、count:<ip>）與 SHM（ban:<ip>、error_count:<ip>:*）記錄。
使用方法：
訪問端點：http://<vhost>/unblock_ip?ip=<IP>。
範例：清除 IP 47.86.7.10 的封鎖：curl -v "http://76cpmg.com/unblock_ip?ip=47.86.7.10"


預期回應：
成功：IP 47.86.7.10 已解除封鎖（HTTP 200）。
無 IP 參數：請提供 IP 參數，例如 ?ip=61.216.73.121（HTTP 400）。
Redis 連線失敗或 SHM 未定義：錯誤訊息（HTTP 500）。


日誌檢查：tail -f /opt/logs/nginx/<vhost>.error.log | grep "unblock_ip"


成功：已從 shm 清除 IP: 47.86.7.10 和 已從 Redis 清除 IP: 47.86.7.10。
失敗：Redis 連線失敗 或 ngx.shared.error_block_dict 未定義。





注意事項

Redis 連線：
block_ip.lua 和 log_error_block.lua 使用 127.0.0.1:6379。
unblock_ip.lua 使用 10.32.0.21:6379，需確保一致性（建議統一配置）。


共享記憶體：需在 nginx.conf 定義 lua_shared_dict error_block_dict 10m;。
GeoIP 性能：API 查詢可能延遲，建議緩存結果到 Redis：local geo_cache_key = "geo:" .. client_ip
local cached_location = red:get(geo_cache_key)
if cached_location == ngx.null then
    cached_location = get_geo_info(client_ip)
    red:setex(geo_cache_key, 86400, cached_location)
end


日誌問題：444 請求記錄到 access_log，可通過 vhost 配置 if=$loggable 過濾（不在本範圍）。

測試方法

模擬高流量（觸發 block_ip.lua）：
for i in {1..1001}; do curl -s -o /dev/null http://<vhost> -H "X-Forwarded-For: 47.86.7.10"; done
redis-cli -h 127.0.0.1 -p 6379 get ban:47.86.7.10


模擬錯誤碼（觸發 log_error_block.lua）：
for i in {1..61}; do curl -s -o /dev/null http://<vhost>/nonexistent -H "X-Forwarded-For: 47.86.7.10"; done


手動解除封鎖：
curl -v "http://<vhost>/unblock_ip?ip=47.86.7.10"
redis-cli -h 10.32.0.21 -p 6379 get ban:47.86.7.10


檢查日誌與通知：
tail -f /opt/logs/nginx/<vhost>.access.log | grep 47.86.7.10
tail -f /opt/logs/nginx/<vhost>.error.log | grep -E "ip-api.com|freeipapi.com|Redis|unblock_ip"
redis-cli -h 127.0.0.1 -p 6379 keys ban:*



問題排查

Redis 連線失敗：
檢查 127.0.0.1:6379 和 10.32.0.21:6379 連線。
確認 unblock_ip.lua 的 Redis 主機一致性。


無通知：檢查 telegram.lua 配置和網路連線。
GeoIP 失敗：驗證 MaxMindDB 或 API（ip-api.com、freeipapi.com）可用性。
SHM 未定義：確保 nginx.conf 包含 lua_shared_dict error_block_dict 10m;。
日誌過多：444 日誌需 vhost 配置 if=$loggable 過濾。

