-- geo_mapping.lua
--   
-- 所有地理名稱對照表統一集中於此檔，方便維護
     
local _M = {}
     
-- ==== 國家對照 ====
_M.country_map = {
    ["Taiwan"]          = "台灣",
    ["China"]           = "中國",
    ["United States"]   = "美國",
    ["Japan"]           = "日本",
    ["South Korea"]     = "韓國",
    ["Singapore"]       = "新加坡",                                                                                                                                                                                                                                                                                                             
    ["Thailand"]        = "泰國",
    ["Vietnam"]         = "越南",
    ["Malaysia"]        = "馬來西亞",
    ["Philippines"]     = "菲律賓",
    ["Indonesia"]       = "印尼",
    ["India"]           = "印度",
    ["Australia"]       = "澳洲",
    ["United Kingdom"]  = "英國",
    ["Germany"]         = "德國",
    ["France"]          = "法國",
    ["Canada"]          = "加拿大",
    ["Brazil"]          = "巴西",
    ["Russia"]          = "俄羅斯",
    -- 需要再加的就自己補
}    
     
-- ==== 城市對照 ====
--   1) 先列常用國際城市
--   2) 接著是「全中國」：四直轄市、各省會、副省級／計劃單列市、特區
--      （如果需要更細，可再往下加縣市，或改用自動化腳本產生 table）
     
_M.city_map = {
    -- 國際常用
    ["Taipei"]                 = "台北",
    ["New Taipei"]             = "新北",
    ["Kaohsiung"]              = "高雄",
    ["Tokyo"]                  = "東京",
    ["Seoul"]                  = "首爾",
    ["Singapore"]              = "新加坡",
    ["Bangkok"]                = "曼谷",
    ["Ho Chi Minh City"]       = "胡志明市",
    ["Kuala Lumpur"]           = "吉隆坡",
    ["Manila"]                 = "馬尼拉",
    ["Jakarta"]                = "雅加達",
    ["Mumbai"]                 = "孟買",
    ["New Delhi"]              = "新德里",
    ["Sydney"]                 = "雪梨",
    ["Los Angeles"]            = "洛杉磯",
    ["New York"]               = "紐約",
    ["London"]                 = "倫敦",
    ["Paris"]                  = "巴黎",
    ["Berlin"]                 = "柏林",
    ["Toronto"]                = "多倫多",
    ["Vancouver"]              = "溫哥華",
    ["Santa Clara"]            = "聖塔克拉拉",
    ["Charleston"]             = "查爾斯頓",
    ["Manado"]                 = "馬納多",
    ["San Jose"]               = "聖荷西",
     
    -- ========= 全中國（直轄市 + 省會 + 副省級 / 計劃單列） =========
    -- 直轄市
    ["Beijing"]                = "北京",
    ["Shanghai"]               = "上海",
    ["Chongqing"]              = "重慶",
    ["Tianjin"]                = "天津",
    -- 兩特區
    ["Hong Kong"]              = "香港",
    ["Macau"]                  = "澳門",
    -- 東北
    ["Shenyang"]               = "瀋陽",
    ["Changchun"]              = "長春",
    ["Harbin"]                 = "哈爾濱",
    -- 華北
    ["Shijiazhuang"]           = "石家莊",
    ["Taiyuan"]                = "太原",
    ["Hohhot"]                 = "呼和浩特",
    -- 華東
    ["Nanjing"]                = "南京",
    ["Hangzhou"]               = "杭州",
    ["Hefei"]                  = "合肥",
    ["Jinan"]                  = "濟南",
    ["Fuzhou"]                 = "福州",
    ["Nanchang"]               = "南昌",
    ["Jinhua"]                 = "金華",
    -- 華中
    ["Wuhan"]                  = "武漢",
    ["Changsha"]               = "長沙",
    ["Zhengzhou"]              = "鄭州",
    ["Hengyang"]               = "衡陽",
    -- 華南
    ["Guangzhou"]              = "廣州",
    ["Shenzhen"]               = "深圳",
    ["Nanning"]                = "南寧",
    ["Haikou"]                 = "海口",
    -- 西南
    ["Chengdu"]                = "成都",
    ["Kunming"]                = "昆明",
    ["Guiyang"]                = "貴陽",
    ["Lhasa"]                  = "拉薩",
    -- 西北
    ["Xi'an"]                  = "西安",
    ["Xining"]                 = "西寧",
    ["Yinchuan"]               = "銀川",
    ["Lanzhou"]                = "蘭州",
    ["Urumqi"]                 = "烏魯木齊",
    -- 計劃單列 / 副省級
    ["Dalian"]                 = "大連",
    ["Qingdao"]                = "青島",
    ["Ningbo"]                 = "寧波",
    ["Xiamen"]                 = "廈門",
    ["Shenzhen"]               = "深圳", -- 已上面列過，這裡保險再寫一次
    ["Suzhou"]                 = "蘇州",
    ["Wuxi"]                   = "無錫",
    ["Foshan"]                 = "佛山",
    ["Dongguan"]               = "東莞",
    ["Hebei"]                  = "河北",
    ["Xianyang"]               = "咸陽",
    ["Pingdingshan"]           = "平頂",
    ["Lishui"]                 = "麗水",
    ["Yangzhou"]               = "揚州",
    ["Wenzhou"]                = "溫州",
    ["Haimen"]                 = "海門",
    ["Yixing"]                 = "宜興",
    ["Meizhou"]                = "梅州",
    ["Qujing"]                 = "曲靖",
    ["Luoyang"]                = "洛陽",
    ["Huaihua"]                = "懷化",
    ["Taizhou"]                = "台州",
    ["Zunyi"]                  = "遵義",
    ["Nanyang"]                = "南陽",
    ["Xiangtan"]               = "湘潭",
    ["Changzhou"]              = "常州",
    ["Jiaxing"]                = "嘉興",
    ["Zibo"]                   = "淄博",
    ["Cangzhou"]               = "凔洲",
    ["Weifang"]                = "濰坊",
    ["Zhuhai"]                 = "珠海",
    -- ……若需其他，如「縣級市」「旗/區」都可繼續擴充
}    
     
return _M

