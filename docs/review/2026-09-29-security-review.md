# 2026-09-29 資安檢查（Claude）

範圍：本機 DB 套用 migration 1–64 後的實際狀態（資料表權限、RLS、67 支 SECURITY DEFINER 函式的最終定義、Storage 政策），以及使用 service role 的 Edge Functions（delete-account、invite、organize-inbox、personal-ai、_shared）。靜態審查與目錄查詢，未對雲端做攻擊測試。

## 修正

- **共用地點快取搶註（MEDIUM，既有問題，migration 15 起）**：`upsert_place` 的「同 id 座標差 1 km 改用替代 key」可被繞過——用戶端能自行傳入含 `~` 的替代 key 預先建立，命中後又不再核對距離。惡意帳號可讓其他人的站點／收藏引用錯誤座標、名稱、地址（影響地圖、路程與外開導航）。
  - migration 64：`~` 保留給服務端，用戶端 id 含 `~` 回 `INVALID_PLACE`；命中的替代列也再核對 1 km，修正前被植入的遠方替代列不沿用，改建此帳號專屬的列。
  - App：iOS 17 無 MapKit identifier 時以店名組 id，店名中的 `~` 換成 `-`。舊版 App 遇到含 `~` 的店名會在部署後被拒（罕見）。
  - `places` 測試新增 2 項。

## 未修正的剩餘風險（需決策）

- 共用 `places` 仍為「第一個寫入者勝」：在 1 km 內搶先註冊某 POI 的帳號，可決定該列名稱與空白的原文名／地址。根本解法是服務端以 Apple Maps Server API 依 provider id 取回權威資料，或改為每個旅程私有地點；需要金鑰與架構決策，本輪未做。

## 確認無問題

- `app` 每張表都啟用 RLS；authenticated 只有 SELECT，寫入全經函式；anon 沒有 `app` schema 使用權。
- 所有 SECURITY DEFINER 函式都設定 `search_path`；worker／解析／佇列／刪帳號等僅 service role 可執行。
- 旅程物件函式皆由資料列推回 trip 後才檢查角色，jsonb 內的 day／stop／item id 均限定同一旅程（含 migration 62 換店、57 預覽）。
- 邀請、角色、移除成員、擁有權移轉、退出不能提權或移除 owner；私人資料（收件、匯入與確認草稿、私人採買、AI 回答、個人 AI 工作）僅本人。
- Storage：購物照片限成員讀、owner／editor 寫；收件照片限本人資料夾。
- Edge Functions 以 JWT 驗身分，service role 查詢均以本人或成員資格過濾；worker 端點以定長比較密鑰；邀請頁 HTML escape 與 CSP；收件抓取限白名單網域（含重導）。
