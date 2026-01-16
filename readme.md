# IP 封鎖與錯誤監控系統

這是一個基於 **OpenResty** 的 IP 封鎖與 HTTP 錯誤監控系統，搭配 **Redis** 實現請求頻率限制與錯誤碼封鎖，並通過 **Telegram** 發送通知。
---
## 版本歷程
- v1 : 僅限次數封鎖的舊版
- v2 : 忘記了，待驗證後刪除
- v3 : 增加監控 HTTP 錯誤碼
- v4 : 增加前端頁面顯示，config共用設定檔
- v5 : 修正log_error_block httpcode 到達次數後直接block
       原來之前版本都只有紀錄跟通知
```
        location = /daily_ip_stats {
            content_by_lua_file /opt/openresty/nginx/conf/conf.d/lua/daily_ip_stats.lua;
            #stub_status on;
        }
    }
```
- v6 : redis key daily:ipcounts 棄用，前端顯示頁改成獲取 redis daily:20260116:101.36.118.185 值
```
原因：daily:ipcounts 只會在 async_ban_process 被執行時累計（透過 ZINCRBY）。
而 async_ban_process 只會被排程（ngx.timer.at）當 Shared Dict 的錯誤計數
new_count >= threshold（ERROR_THRESHOLDS[status]）時才會建立。
你 10 次 404 並未達到預設 threshold（預設通常是 80），因此沒有排程 timer，
handler 沒執行，Redis 的 daily:ipcounts 就不會增加。

block_ip.lua 的 count:* keys 是「request rate」(連線/頻率) 的即時計數，
與 log_error_block.lua 的錯誤碼封鎖/每日統計（daily:ipcounts）是不同用途。
daily:ipcounts 對應 log_error_block.lua（錯誤碼達 threshold 時做的每日排名），
count:... 對應 block_ip.lua（超高請求率時的封鎖）。
```
---

---

## 📂 專案結構
```
.
├── lua
│   ├── block_ip.lua          # 檢查請求頻率，超過閾值封鎖 IP
│   ├── geo_mapping.lua       # GeoIP 城市與國家名稱映射
│   ├── list_count.sh         # 列出 Redis 計數與封鎖記錄
│   ├── log_error_block.lua   # 監控 HTTP 錯誤碼，超過閾值封鎖
│   ├── telegram.lua          # Telegram 通知模組
│   ├── unblock_ip.lua        # 手動解除 IP 封鎖
│   └── whitelist.txt         # 白名單 IP 列表
│   └── daily_ip_stats.lua    # 前端顯示頁
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
```

---

## ⚙️ 功能概述

### 1. 請求頻率封鎖 (`block_ip.lua`)
- **觸發條件**：180 秒內請求超過 **1000 次**  
- **動作**：設置 `ban:<ip>`（3600 秒），返回 **HTTP 444**  
- **白名單**：跳過檢查並清除 Redis 記錄  
- **通知**：發送 Telegram 訊息，包含 IP 位置（MaxMindDB 或 API 查詢）  

---

### 2. HTTP 錯誤碼封鎖 (`log_error_block.lua`)
- **監控錯誤碼**：`400, 401, 403, 404`  
- **觸發條件**：120 秒內錯誤數超過閾值  
  - `400 → 30 次`  
  - `401 → 20 次`  
  - `403 → 50 次`  
  - `404 → 60 次`  
- **動作**：設置 `ban:<ip>`（3600 秒）並清除計數  
- **實現方式**：
  - 使用 `ngx.shared.error_block_dict` 計數  
  - `ngx.timer.at` 異步寫入 Redis  
- **通知**：發送 Telegram 訊息，包含錯誤詳情與 IP 位置  

---

### 3. GeoIP 查詢
- 優先使用 **MaxMindDB**  
- 若無城市資訊 → 查詢 `ip-api.com` 或 `freeipapi.com`  
- **格式範例**：
  ```
  Hong Kong, 香港 (HK)
  ```

---

### 4. 白名單 (`whitelist.txt`)
- 路徑：`/opt/openresty/nginx/conf/conf.d/lua/whitelist.txt`  
- 功能：白名單 IP **跳過封鎖** 並清除 Redis、SHM 記錄  

---

### 5. 手動解除封鎖 (`unblock_ip.lua`)
- 清除指定 IP 的 Redis 與 SHM 記錄  
- **使用方式**：
  ```bash
  curl -v "http://<vhost>/unblock_ip?ip=<IP>"
  ```
- **範例**：
  ```bash
  curl -v "http://76cpmg.com/unblock_ip?ip=47.86.7.10"
  ```

- **回應結果**：
  - ✅ 成功：`IP 47.86.7.10 已解除封鎖 (HTTP 200)`
  - ❌ 缺少 IP：`請提供 IP 參數，例如 ?ip=61.216.73.121 (HTTP 400)`
  - ⚠️ 錯誤：Redis 連線失敗或 SHM 未定義 (HTTP 500)  

---

## 🛠️ 環境需求
- **OpenResty**：支援 `resty.redis` 與 `resty.http`
- **Redis**：
  - `block_ip.lua` / `log_error_block.lua` → `127.0.0.1:6379`
  - `unblock_ip.lua` → `10.32.0.21:6379`（⚠️ 建議統一配置）
- **MaxMindDB**：提供 GeoIP 查詢（可選）
- **Telegram Bot**：需在 `telegram.lua` 配置 Token

---

## 📝 Nginx 配置
在 `nginx.conf` (`http {}` 區塊) 添加：

```nginx
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
```

---

## 🔎 測試方法

### 模擬高流量（觸發 `block_ip.lua`）
```bash
for i in {1..1001}; do curl -s -o /dev/null http://<vhost> -H "X-Forwarded-For: 47.86.7.10"; done
redis-cli -h 127.0.0.1 -p 6379 get ban:47.86.7.10
```

### 模擬錯誤碼（觸發 `log_error_block.lua`）
```bash
for i in {1..61}; do curl -s -o /dev/null http://<vhost>/nonexistent -H "X-Forwarded-For: 47.86.7.10"; done
```

### 手動解除封鎖
```bash
curl -v "http://<vhost>/unblock_ip?ip=47.86.7.10"
redis-cli -h 10.32.0.21 -p 6379 get ban:47.86.7.10
```

### 日誌檢查
```bash
tail -f /opt/logs/nginx/<vhost>.access.log | grep 47.86.7.10
tail -f /opt/logs/nginx/<vhost>.error.log | grep -E "ip-api.com|freeipapi.com|Redis|unblock_ip"
redis-cli -h 127.0.0.1 -p 6379 keys ban:*
```

---

## ⚠️ 注意事項

- **Redis 連線**  
  建議統一使用相同 Redis 主機，避免 `127.0.0.1` 與 `10.32.0.21` 混用。  

- **共享記憶體 (SHM)**  
  確保在 `nginx.conf` 定義：
  ```nginx
  lua_shared_dict error_block_dict 10m;
  ```

- **GeoIP 性能**  
  API 查詢可能延遲，建議 **緩存到 Redis**：
  ```lua
  local geo_cache_key = "geo:" .. client_ip
  local cached_location = red:get(geo_cache_key)
  if cached_location == ngx.null then
      cached_location = get_geo_info(client_ip)
      red:setex(geo_cache_key, 86400, cached_location)
  end
  ```

- **日誌過多問題**  
  `444` 請求會寫入 `access_log`，可透過 vhost 配置 `if=$loggable` 過濾。

---

## 🐞 問題排查

- Redis 連線失敗 → 檢查 `127.0.0.1:6379` 與 `10.32.0.21:6379`  
- 無通知 → 確認 `telegram.lua` 配置與網路狀態  
- GeoIP 查詢失敗 → 測試 MaxMindDB 與 API 可用性  
- SHM 未定義 → 檢查 `nginx.conf` 是否包含 `lua_shared_dict error_block_dict 10m;`  
- 日誌過多 → 配置 `if=$loggable` 過濾  
