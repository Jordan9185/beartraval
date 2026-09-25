# CLAUDE.md

原生 iOS 旅行助手 App（SwiftUI + Share Extension）。產品規格在 `docs/spec/`，技術規劃在 `docs/planning/`。

## 不可違反的產品規則（摘自規格 §1）

- 正式行程只能由使用者確認後變更；AI 只能產生 proposal。
- Fixed Stop（航班、訂位、使用者標記）不可由 AI 移動；衝突必須明確顯示。
- 地點不確定時列候選並要求確認，不可猜一間寫入正式行程；未確認地點不得參與路線計算。
- 「順路」= 加入後增加的旅行時間（detour minutes），不是直線距離。路線無法計算時回傳 unknown，不可編造分鐘數。
- Saved（地點）與 Shopping（商品）是兩個不同清單。
- 「可能販售」≠「有庫存」；沒有可靠來源時顯示「庫存未知」。
- 好友新增地點預設進共同 Saved，不直接改正式行程。
- 權限一律由服務端驗證；正式行程提交需檢查 revision，過期 proposal 不可靜默覆蓋。

## 慣例

- 文件以繁體中文撰寫。
- 使用者介面一律繁體中文（分頁：今天／旅程／地圖／收藏／購物）。店名、地名等專有名詞保留原文，並在旁附註繁體中文，例如「명동교자 본점（明洞餃子本店）」；外開在地地圖時用原文。
- 規劃文件中每項標註：【已確認規格】／【建議】／【需實測或決策】。

## 已確認技術決策（詳見 docs/planning/mvp-technical-plan.md §6）

- 後端 Supabase（Postgres + RLS + Realtime + Edge Functions）；iOS 17+；登入用 Email＋密碼（D7，2026-09-24 改定）。
- 路線與 POI：MVP 只用 Apple Maps；算不出時顯示無法估算。韓國地點提供按鈕外開 Naver／Kakao 地圖（帶店名、座標、起點、交通方式），不串接其 API、不讀回分鐘數（§4.3.1）。
