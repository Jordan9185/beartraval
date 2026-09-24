# iOS AI Travel Companion — MVP 技術規劃 v0.1

日期：2026-09-24 · 依據：[MVP 規格草案 v0.1](../spec/ios-ai-travel-companion-mvp-spec.md)、[規劃任務](../spec/claude-ios-planning-brief.md)

標記說明：
- **【規格】** 已確認規格，本文件不重新討論。
- **【建議】** 我的建議，可調整。
- **【實測】** 需要實機／實地驗證才能定案。
- **【決策】** 需要你決定（彙整於第 6 節）。

本文件只做規劃與風險，不含程式碼。確認後再拆成開發任務。

---

## 1. 架構總覽

```
┌─────────────────────────── iOS 裝置 ───────────────────────────┐
│  iOS App (SwiftUI)                    Share Extension          │
│  ├ Features: Today/Trip/Map/          ├ 讀取 NSItemProvider      │
│  │  Saved/Shopping/AI/Import          ├ 產生 ShareDraft          │
│  ├ AppCore (SPM)  ◄─────共用─────────►├ AppCore (精簡子集)        │
│  │  Domain 模型、規則、API client      └ 呼叫後端 / 寫 App Group  │
│  ├ LocalCache (唯讀快取 + 待送佇列)                               │
│  └ MapKit 顯示（地圖、Pin）                                       │
│             App Group：ShareDraft、auth token（Keychain 共享）    │
└──────────────────────────────┬─────────────────────────────────┘
                               │ HTTPS (JWT) + Realtime 訂閱
┌──────────────────────────────▼─────────────────────────────────┐
│ 後端（建議 Supabase：Postgres + Auth + Realtime + Edge Functions）│
│  ├ Postgres：唯一真實來源；RLS 落實成員權限                         │
│  ├ RPC（交易）：commit_import、confirm_proposal、purchase …        │
│  │   ─ 檢查 role 與 revision，失敗回 409 STALE_REVISION            │
│  ├ Realtime：trip 頻道只推「變更通知」，客戶端重新拉取              │
│  ├ AI Gateway（Edge Function）：解析、問答、proposal；schema 驗證   │
│  ├ Place Service：POI 搜尋、分店去重、Place 快取                   │
│  └ Route Service：RoutingProvider 抽象 + 旅行時間快取 + Route Match │
└──────┬──────────────────────┬──────────────────────┬────────────┘
       ▼                      ▼                      ▼
   LLM API（Claude）   地圖/POI 供應商（Apple Maps     外部來源
   只產生草稿/proposal  Server API／MapKit）         （OG metadata、
                       MVP 只用 Apple）              官方店鋪頁）
```

### 責任邊界

| 元件 | 負責 | 不負責 | 標記 |
|---|---|---|---|
| iOS App | UI、使用者確認、快取顯示、離線唯讀 | 權限判定、Route Match 權威結果、正式寫入的最終判定 | 【建議】 |
| Share Extension | 讀分享 payload、最小確認卡、建立 ShareDraft、送出 | 重運算（AI／路線）；記憶體上限低，只做輕量工作 | 【建議】 |
| 後端 DB/RPC | 正式行程、權限、revision、事件 | 推測地點 | 【規格】權限在服務端 |
| AI Gateway | 文字→結構化草稿、問答、proposal | 直接寫入正式 Stop；把模型輸出當地址/營業時間/庫存事實 | 【規格】 |
| Route Service | Base Route、Route Match、可行性檢查 | 用直線距離代替旅行時間 | 【規格】 |
| Place Service | POI 查詢、候選分店、去重 | 自動選定歧義分店 | 【規格】 |

**為何 Route Match 放在服務端【建議】**：同一 Trip 的旅伴要看到同一個 detour 數字（同一 base_revision、同一供應商、同一快取）；且 Route Match 需要多次路線查詢，集中快取可控成本。若 Spike S1 顯示只有裝置端 MapKit 可用（例如 transit），則改為「裝置計算、上傳結果並標記 provider=device」，仍以 base_revision 綁定。【實測】

---

## 2. Work Packages（依賴順序）

原則：先打通主流程 1（文字匯入 → 正式行程 → Base Route），再做 Route Match，再接分享與購物；共用、AI 助手最後疊上。Spike 先行，因為它們決定供應商與後端選型。

| WP | 範圍 | 先決條件 | 完成證據 | 對應 AC |
|---|---|---|---|---|
| **S1 路線/POI Spike** | 首爾、廣島的 POI 搜尋、分店、步行/大眾運輸/開車時間；只測 Apple（MapKit、Apple Maps Server API），記錄哪些模式／地區算不出（見 §4.3.1） | 無 | 實測表（見 §4.4）、供應商建議 | AC-05, 14 |
| **S2 分享 payload Spike** | 除錯用 Extension 記錄 Threads/IG 各種分享的型別與內容 | 無 | payload 矩陣（見 §5） | AC-03, 04 |
| **S3 AI 解析 Spike** | 20+ 份真實行程文字（ChatGPT/LINE/備忘錄）跑解析 schema | 無 | 欄位準確率、失敗類型、延遲、每次成本 | AC-01 |
| **S4 後端 PoC** | 決策 D1 的候選，驗證 RLS 權限、revision RPC、Realtime | D1 | 權限自動化測試 + 兩客戶端收斂示範 | AC-12, 13 |
| **WP1 基礎建設** | Xcode 專案、SPM 模組（AppCore/Features/ShareExt）、App Group、Sign in with Apple、CI（build+unit test）、DB schema v0 + RLS | S4、D1、D2 | CI 綠燈；模擬器登入並建立空 Trip | — |
| **WP2 正式行程核心** | Trip/TripDay/Stop/Place 模型、`commit_itinerary` RPC（revision 檢查）、Trip 時間軸（唯讀）、空狀態 | WP1 | RPC 整合測試；Trip 頁顯示 DB 資料 | AC-02（部分） |
| **WP3 文字匯入管線** | Import→Parsing→Confirm Places→Create；保留原文；候選分店；待確認文字 Stop | WP2、S3、S1（POI） | XCUITest：歧義分店未選不能提交；失敗重試不丟原文 | AC-01, 02 |
| **WP4 Base Route + Route Match** | RoutingProvider 抽象、旅行時間快取、Base Route 版本、Route Match 演算法、可行性、unknown 狀態 | WP2、S1 | 演算法單元測試（固定假資料）；首爾/廣島實測報告 | AC-05, 06, 14 |
| **WP5 加入行程（Proposal）** | ChangeProposal 流程：顯示 +N 分鐘與衝突 → 確認 → 提交；STALE 處理 | WP4 | 並發測試：兩客戶端同日修改，第二個收到 STALE 並重新確認 | AC-08, 13 |
| **WP6 Saved + Share Extension** | Saved 清單/篩選/想去；Extension 最小閉環；手動補填；重複分享去重 | WP4、WP5、S2 | 真機錄影：Threads、IG 各一次成功與一次資料不足 | AC-03, 04 |
| **WP7 共用與權限** | 邀請連結（token）、Owner/Editor/Viewer、Realtime 同步 Saved/Shopping/行程、重連收斂 | WP2、S4 | 兩裝置測試錄影；API 直接呼叫被拒的測試 | AC-07, 12, 13 |
| **WP8 Shopping** | 商品、MerchantCandidate（證據、庫存 unknown）、依 detour 排序、Purchase Stop、購買/撤銷事件 | WP4、WP5、WP7 | XCUITest + 兩裝置購買同步 | AC-09, 10, 11 |
| **WP9 Today + Map 彙整** | Today 首屏摘要、順路 Saved、今日可買；Map 圖層、Pin 詳情、已購降權 | WP4、WP6、WP8 | 截圖對照：三頁同一份資料、同一 revision | AC-02, 11 |
| **WP10 AI 助手** | Trip 範圍問答（引用 Stop/Route Match/來源）、proposal 產生，Apply 走 WP5 流程 | WP5、WP9 | 評測集：無資料時回「無法判斷」；proposal 不直接寫入 | 規則 1、2 |
| **WP11 強化與驗收** | 全部錯誤/空/離線狀態、刪除策略、可觀測性、實地測試 | 全部 | 驗收報告（§7） | 全部 |

**核心路徑里程碑**：M1 = WP1–WP4（模擬器走通流程 1 與 Route Match）→ M2 = WP5–WP6（真機分享閉環）→ M3 = WP7（兩人兩裝置）→ M4 = WP8–WP10 → M5 = WP11 實地驗收。

S1–S3 可平行，建議在 WP1 開始前完成或至少出初步結論。

---

## 3. 資料模型、契約、權限、衝突與錯誤

### 3.1 資料模型調整【建議】

在規格 §4 的基礎上：

| 實體 | 變更/新增 | 理由 |
|---|---|---|
| Trip | 保留 `revision`；`primary_city` 可空直到使用者確認 | 【規格】城市需確認 |
| TripDay | 新增 `time_zone`（預設繼承 Trip）、`transport_mode`、`route_revision` | 跨時區行程；每日交通方式可不同 |
| Stop | `start_time` 存「當地時間 + day 時區」；新增 `end_time`（可空）、`deleted_at`（軟刪除）；`place_id` 為空時 `resolution_status = pending_text` | 【規格】待確認文字 Stop 不參與路線 |
| ImportSession（新） | trip_id、raw_text、parse_status、parse_result(JSON)、model 版本、created_by | 保留原文供校對、失敗重試 |
| PlaceCandidate（新） | import_stop_ref / saved_id、place_id、rank、evidence | 候選分店在確認前不進 Stop |
| Place | `provider`＋`provider_place_id` 唯一；多語名稱；`opening_hours`（含來源與取得時間，可空） | 去重；營業時間須有來源 |
| BaseRoute（新） | day_id、route_revision、legs[]（from/to/minutes/provider/計算時間）、total_minutes、status | 「可追溯版本」AC-02 |
| SourceReference | 新增 `canonical_url` + `content_hash` | 重複分享去重 |
| SavedPlace | `status`: saved/added_to_itinerary/dismissed；「想去」拆成 SavedInterest(saved_id, user_id) | 集合操作無衝突；已加入行程不重複出現 |
| ShoppingItem | 「想買」拆成 ShoppingInterest；購買狀態由 PurchaseEvent 推導 | 規格 §5.4：誰想買 ≠ 誰買到 |
| PurchaseEvent（新） | item_id、actor、type(purchased/undone)、at | 可撤銷、保留紀錄、無覆蓋衝突 |
| MerchantCandidate | `evidence_url`、`evidence_type`（official_locator/poi_category/user）、`evidence_expires_at`；`inventory_status` 只有 unknown/verified | 【規格】庫存與販售分開 |
| RouteMatch | 規格欄位 + `added_travel_minutes`、`added_dwell_minutes`、`feasibility`、`conflicts[]`、`provider` | 見 §4 |
| ChangeProposal | 規格欄位 + `expected_route_revision`、`created_by_ai` | STALE 判定 |
| Invite（新） | trip_id、token_hash、role、expires_at、max_uses、revoked_at | 邀請不可用公開 Trip ID |

**刪除策略【建議】**：協作資料（Stop/Saved/Shopping）軟刪除並保留 30 天墓碑以便同步收斂；刪除 Trip 時硬刪除原文與 AI 紀錄；帳號刪除（App Store 要求）時硬刪個人資料並把協作紀錄的 actor 匿名化。

### 3.2 API／RPC 契約（草案）【建議】

| 操作 | 輸入 | 輸出 / 錯誤 |
|---|---|---|
| `create_trip` | name, start, end | Trip |
| `create_import` / `parse_import` | trip_id, raw_text | ImportSession（`parsing`→`parsed`/`failed`） |
| `commit_import` | import_id, resolved_stops[], expected_trip_revision | Trip + 每日 BaseRoute 計算工作；`PLACE_UNRESOLVED`、`STALE_REVISION` |
| `route_match` | trip_id, place_id, day_ids?, mode? | RouteMatch[]；`PLACE_UNRESOLVED`、`ROUTE_UNAVAILABLE` |
| `create_proposal` | trip_id, day_id, change, expected_route_revision | ChangeProposal（含 +N、衝突） |
| `confirm_proposal` | proposal_id, expected_route_revision | 新 revision；`STALE_REVISION` → proposal 標 stale |
| `save_place` / `set_interest` | trip_id, source, place/raw_label | SavedPlace；重複時回既有項目 |
| `create_item` / `find_merchants` / `schedule_purchase` | … | ShoppingItem / MerchantCandidate[] / Purchase Stop（走 proposal） |
| `record_purchase` / `undo_purchase` | item_id | PurchaseEvent |
| `create_invite` / `accept_invite` | trip_id, role / token | Invite / TripMember；`INVITE_EXPIRED`、`INVITE_REVOKED` |
| `ask_ai` | trip_id, question | 回答 + 引用 + 可選 proposal_id |

**Realtime 事件**（每 Trip 一個頻道，只帶 id 與 revision，不帶完整資料）：`trip.revision_changed`、`day.route_changed`、`saved.changed`、`shopping.changed`、`member.changed`。客戶端收到後依 revision 拉取；重連時以 `since_revision` 補拉，保證收斂。

**AI 解析輸出 schema**：依規格 §5.1（days[] → stops[]，含原文片段、時間候選、地點名稱、confidence、fixed_suspected、unresolved_reason），由 Gateway 以 JSON Schema 驗證；不合法即視為 `PARSE_FAILED`，不部分寫入。

### 3.3 權限矩陣

| 操作 | Owner | Editor | Viewer | 未加入 | 標記 |
|---|---|---|---|---|---|
| 讀取 Trip / Saved / Shopping | ✅ | ✅ | ✅ | ❌ | 【規格】 |
| 新增 Saved、想去、商品、想買 | ✅ | ✅ | ❌ | ❌ | 【規格】 |
| 提出 proposal | ✅ | ✅ | ❌ | ❌ | 【規格】 |
| 確認 proposal／修改正式行程 | ✅ | ✅ | ❌ | ❌ | 【規格】 |
| 標記購買 / 撤銷 | ✅ | ✅ | ❌ | ❌ | 【建議】撤銷僅限購買者本人或 Owner |
| 建立邀請 | ✅ | ❌ | ❌ | ❌ | 【建議】【決策 D5】是否允許 Editor 邀請 |
| 變更成員角色、移除成員、刪除 Trip | ✅ | ❌ | ❌ | ❌ | 【規格】 |
| 使用 AI 助手（問答） | ✅ | ✅ | ✅（僅問答，不能 Apply） | ❌ | 【建議】 |

全部以 RLS + RPC 內角色檢查實作；測試直接呼叫 API（繞過 UI）驗證拒絕（AC-12）。

### 3.4 版本衝突設計

| 資料 | 策略 | 標記 |
|---|---|---|
| 正式行程（Stop） | 樂觀鎖：每個寫入帶 `expected_route_revision`；不符 → `STALE_REVISION`；UI 顯示新版本並要求重新確認（proposal 重算 detour） | 【規格】不靜默覆蓋 |
| Saved / Shopping 欄位 | 欄位層級 last-writer-wins + actor/時間；刪除優先於編輯 | 【建議】 |
| 想去 / 想買 | 以成員列表示（集合），天然無衝突 | 【建議】 |
| 購買狀態 | 事件紀錄（purchase/undo），狀態由最新事件推導 | 【建議】 |
| 離線 | 行程修改必須在線；Saved/Shopping 新增、想去、購買可離線入佇列，重連時送出（idempotency key 防重送） | 【建議】【決策 D6】 |

### 3.5 錯誤狀態

| 代碼 | 觸發 | UI 行為 |
|---|---|---|
| `PARSE_FAILED` | AI 失敗或 schema 不合法 | 保留原文，可重試或編輯原文 |
| `PLACE_UNRESOLVED` | 地點未確認 | 顯示候選或手動輸入；不計算路線 |
| `NO_PLACE_FOUND` | 查無店家 | 手動輸入名稱/連結，存為待確認 |
| `ROUTE_UNAVAILABLE` | 供應商不支援該模式/地區或失敗 | 顯示「無法估算」，不顯示分鐘數（AC-14） |
| `PROVIDER_RATE_LIMITED` | 路線/POI 被節流 | 稍後重試，顯示計算中 |
| `FIXED_CONFLICT` | 插入會讓固定 Stop 遲到 | 顯示衝突與超出分鐘，提供收藏/換日 |
| `STALE_REVISION` | 他人已修改 | 重新載入並要求重新確認 |
| `FORBIDDEN_ROLE` | 權限不足 | 隱藏/停用操作 + 服務端拒絕 |
| `INVITE_EXPIRED` / `INVITE_REVOKED` | 邀請失效 | 說明並請 Owner 重發 |
| `OFFLINE` | 無網路 | 唯讀快取 + 待送項目提示 |
| `SHARE_INSUFFICIENT` | 分享內容不足 | 列出缺少資訊，要求補填（AC-04） |

---

## 4. Route Match 演算法與實地驗證

### 4.1 定義【規格】

`detour_minutes = max(0, candidate_route_minutes − base_route_minutes)`，同一交通模式、同一計算基準；停留、營業時間、固定時間衝突屬於「可行性」，不併入 detour。

### 4.2 演算法【建議】

輸入：某日已確認地點的 Stop 序列 `S0..Sn`（`pending_text` Stop 排除並在結果中註明）、候選地點 `C`、交通模式 `m`、候選停留 `dwell_C`。

1. **Base**：`B = Σ t(Si, Si+1)`，取自 BaseRoute（已快取，含 revision）。
2. **插入位置**：k = 0..n+1。中間位置 `Δk = t(Sk, C) + t(C, Sk+1) − t(Sk, Sk+1)`；頭尾位置為 `t(C, S0)` 或 `t(Sn, C)`（頭尾是否允許插入【決策 D9】：若當日以飯店為起訖，只允許中間）。
3. **查詢次數**：每個位置需要 2 次新查詢，n ≤ 12 時全部精算（≤ 26 次，快取後大多命中）。n 更大時先用直線距離／估速排序取前 5 個位置精算，結果標記 `approximate=true`。
4. **時間依賴**：transit/drive 用該段預計出發時間查詢；快取鍵 `(from, to, mode, 30 分鐘時段)`。
5. **可行性（與 detour 分開）**：將 C 插入位置 k 後，以 Stop 的時間與停留模擬當日時間軸：
   - `added_travel_minutes = Δk`
   - `added_dwell_minutes = dwell_C`（依類別預設：Cafe 45、Eat 60、Shop 30、Place 60，可改）
   - 對 k 之後第一個 Fixed Stop F：`slack = F.start − 預計抵達`。`slack < 0` → `FIXED_CONFLICT(F, −slack)`
   - C 的營業時間若有可信來源則檢查，否則 `opening_hours = unknown`（不當作可行或不可行）
   - 無時間的 Flexible Stop 不檢查
6. **最佳插入點**：可行者中取最小 Δk；同分取 slack 較大者。無可行者時仍回傳最小 Δk 並附衝突原因（AC-06）。
7. **最佳日**：各日最佳結果中，可行優先、Δ 最小者。
8. **失效**：任何一段 `t` 無法取得 → 該位置 unknown；全部 unknown → 結果 `ROUTE_UNAVAILABLE`，不輸出數字（AC-14）。BaseRoute revision 改變 → 既有 RouteMatch 標記過期並重算。

UI 顯示三個分開的數字：**+N 分鐘路程**、**+M 分鐘停留**、**與下一個固定行程的餘裕／衝突**。

### 4.3 供應商風險【實測】

- MapKit `MKDirections` 的大眾運輸在很多地區只提供 ETA（`calculateETA`）而非完整路線；Route Match 只需要時間，ETA 可能足夠，但須實測首爾、廣島是否回傳。
- 韓國地圖資料有出口限制：Apple 在韓國沒有大眾運輸路線，步行／開車精度有疑慮（見 §4.3.1）。
- 服務端若要呼叫 Apple，候選是 Apple Maps Server API（ETA、搜尋），需驗證區域覆蓋與配額。
- 裝置端 MKDirections 有節流；大量插入位置計算可能觸發。

### 4.3.1 MVP 只用 Apple Maps【已決策：D3，2026-09-24】

MVP 的路線與 POI 只用 Apple（MapKit／Apple Maps Server API）。韓國在地服務延後，但架構保留 `RoutingProvider` 抽象，之後可接上。

**已知的 Apple 在韓國限制（2026-09 網路資料，待 S1 實測）**

| 模式 | Apple 地圖 App 現況 | MVP 行為 |
|---|---|---|
| 大眾運輸 | 不提供，轉到第三方 App | 預期回傳 unavailable → 顯示「無法估算」 |
| 步行 | 2025 年起有，但缺斑馬線、樓梯、地下道等細節 | 可用，誤差待實測 |
| 開車 | 有逐向導航，高精度地圖出口仍未獲准 | 可用，誤差待實測 |

**MVP 規則**

1. 首爾若當日交通模式為大眾運輸且 Apple 算不出，該日 Route Match 為 `ROUTE_UNAVAILABLE`；UI 提示可改用步行或開車估算，不編造分鐘數（AC-14）。
2. 同一天、同一交通模式的 Base Route 與 Route Match 使用同一供應商與同一計算基準。
3. 結果記錄 `provider`，之後加入其他供應商時可區分。

**之後的在地服務候選（未排入 MVP）**

| 模式 | 候選 | 外國人申請（網路資料，未驗證） |
|---|---|---|
| POI | Kakao Local | 可用國外手機號碼註冊，約 3–5 天審核 |
| 開車 | Kakao Mobility、Naver Directions | Kakao Mobility 需另外申請使用權限；Naver Cloud 個人帳號通常需韓國手機＋外國人登錄證 |
| 步行 | TMAP | 申請入口僅韓文，外國人可否申請未知 |
| 大眾運輸 | ODsay LAB、TMAP | 未知 |

### 4.4 首爾／廣島驗證方案

| 項目 | 內容 |
|---|---|
| 測試點 | 每城市 25 組 OD：首爾（明洞、聖水、弘大、延南洞、江南、東大門、汝矣島…）；廣島（廣島站、和平紀念公園、本通、宮島口、宇品港…）。含 5 組「直線近但需繞路」案例（河川、鐵路、山坡）驗證 AC-05 |
| 交通模式 | 步行、大眾運輸、開車（計程車） |
| 參考值 | 手動紀錄 Naver Map / Kakao Map（首爾）、Google Maps / Japan Transit Planner（廣島）同時段結果 |
| 指標 | 回傳率（非 unknown 比例）；與參考值誤差（中位數、P90）；延遲；每千次成本 |
| 通過門檻【建議】 | 回傳率 ≥ 90%；中位數誤差 ≤ 20% 或 ≤ 5 分鐘；P90 ≤ 35% |
| POI | 30 個查詢（韓/日/英/中文名、連鎖店如 Olive Young、ReFa 取扱店、UNIQLO 分店），紀錄是否找到、分店是否可區分、地址正確率、多語名稱 |
| 產出 | `docs/research/route-poi-spike.md` + 原始 CSV；供應商建議（決策 D3） |
| 實地 | M5 在當地以真機跑 3 天行程，記錄 Route Match 建議與實際花費時間 |

---

## 5. Share Extension（Threads／IG）驗證計畫

### 5.1 驗證方法【建議】

1. 建立除錯用 **Payload Inspector** Extension：啟用所有型別（URL、text、image、movie、property list），對每個 `NSItemProvider` 記錄 `registeredTypeIdentifiers`、實際載入內容（截斷）、大小、耗時，寫入 App Group 並可在 App 內匯出。
2. 測試矩陣（每格記錄得到什麼）：

| 來源 | 內容類型 | 分享方式 |
|---|---|---|
| Threads | 純文字 / 單圖 / 多圖 / 影片 / 含地點標籤 | 分享鈕 → 分享到…；複製連結 |
| Instagram | 貼文單圖 / 輪播 / Reels / 含地點 / 地點頁 / 限動 | 分享鈕 → 分享到…；複製連結 |
| 對照 | Safari、Google Maps、Apple Maps、Naver/Kakao Map | 分享 |

3. 紀錄 iOS 版本與 App 版本（主機 App 更新可能改變 payload，需在 WP11 重測）。

### 5.2 預期與退路【實測】

預期（待驗證）：IG 多半只提供貼文 URL；Threads 可能提供 URL 與部分文字；圖片通常拿不到原圖。

退路（依序）：
1. **URL**：服務端抓 Open Graph metadata（標題、描述、地點）；遇登入牆就放棄，不嘗試繞過。
2. **文字**：AI 抽取候選店名，一律進確認。
3. **截圖**：使用者從相簿選截圖，裝置端 Vision OCR 抽文字再送 AI（不上傳原圖，除非使用者同意）。
4. **手動**：輸入店名或貼地圖連結（Google/Apple/Naver/Kakao Maps URL 可直接解析座標）。
5. 任何一步不足都顯示「缺少哪些資訊」（AC-04），不顯示假辨識結果。

### 5.3 Extension 限制【建議】

- 記憶體與執行時間有限：Extension 只建立 ShareDraft、呼叫後端辨識、顯示結果；Route Match 由後端計算並回傳。
- 未登入或無網路：ShareDraft 存 App Group，提示「開啟 App 繼續」。
- 共享登入：Keychain access group 讓 Extension 取用 token。
- 重複分享：`canonical_url` 相同即回既有 Saved 並更新「想去」。

---

## 6. 決策紀錄

**2026-09-24 已決策**：D1–D11 全部採用下表「我的建議」。D3 更新：MVP 先只用 Apple Maps，韓國在地服務延後（見 §4.3.1）。


| # | 問題 | 選項 | 影響 | 我的建議 |
|---|---|---|---|---|
| D1 | 後端 | A. Supabase（Postgres+RLS+Realtime）B. Firebase（Firestore+Rules）C. CloudKit 共享 + 自建 AI 服務 | A 權限與 revision 交易最直觀、可 SQL 測試；B 離線同步強但交易/複雜規則較難；C 無法做 Web 邀請頁、仍需另一個後端跑 AI | **A** |
| D2 | iOS 最低版本 | iOS 17 / iOS 18 | 17 可用 Observation、SwiftData、新 MapKit SwiftUI API；18 減少相容處理但排除部分裝置 | **iOS 17** |
| D3 | 路線/POI 供應商 | Apple 全包 / Apple + 韓國在地供應商 / Google | 成本、韓國覆蓋、授權條款 | **MVP 只用 Apple**；保留 RoutingProvider 抽象，韓國在地服務延後（§4.3.1） |
| D4 | 免安裝 Web 邀請頁 | 不做 / 唯讀預覽+導向下載 / Web 可編輯 | 範圍與安全面擴大 | **唯讀預覽（Trip 名稱、日期、邀請者）+ Universal Link**，不顯示行程內容、不做 Web 編輯 |
| D5 | Editor 可否邀請 | 僅 Owner / Owner+Editor（只能邀 Viewer/Editor） | 協作便利 vs 控制 | **僅 Owner**（MVP） |
| D6 | 離線範圍 | 唯讀 / 唯讀+Saved/Shopping/購買可離線 / 全離線 | 複雜度 | **唯讀 + 非行程操作可離線**；行程修改需在線 |
| D7 | 登入方式 | Sign in with Apple / + Email magic link / + Google | 好友邀請門檻 | **Sign in with Apple + Email magic link** |
| D8 | 商品販售證據來源 | 官方店鋪查詢頁 / POI 類別 / 使用者提供 | 準確度與維護 | **官方店鋪頁（附連結）優先，其次使用者提供；證據 30 天過期**，一律「可能販售、庫存未知」 |
| D9 | 每日起訖點 | 無 / 每日可設住宿為起訖 | Route Match 頭尾插入是否合理 | **可設住宿**；未設時允許頭尾插入 |
| D10 | 預設交通方式 | 步行+大眾運輸 / 開車 / 每日設定 | 路線供應商需求 | **每日可設，預設大眾運輸（含步行）**，但依 S1 結果可能需改預設 |
| D11 | AI 資料保存 | 原文與對話保存期限 | 隱私、刪除 | **隨 Trip 保存，刪 Trip 即刪**；不記錄完整 prompt 於日誌 |

（不重開：分頁結構、AI 只提 proposal、Fixed 不可動、Saved/Shopping 分開、detour 定義、庫存未知等規格已確認的 UX 原則。）

---

## 7. MVP 交付與驗收計畫

### 7.1 AC 驗證環境

| AC | 模擬器可驗證 | 必須真機／實際環境 | 證據 |
|---|---|---|---|
| AC-01 | ✅（固定文字） | — | XCUITest + 螢幕錄影 |
| AC-02 | ✅ | — | 三頁截圖 + DB revision 紀錄 |
| AC-03 | 部分（模擬 payload） | ✅ Threads/IG 真機 | 真機錄影 + payload log |
| AC-04 | 部分 | ✅ 真機 | 真機錄影 |
| AC-05 | ✅（假路線供應商） | ✅ 實際供應商首爾/廣島 | 單元測試 + S1 報告中的繞路案例 |
| AC-06 | ✅ | — | 單元測試 + UI 錄影 |
| AC-07 | — | ✅ 兩裝置兩帳號 | 雙機同框錄影 |
| AC-08 | ✅ | — | XCUITest |
| AC-09 | ✅ | — | XCUITest |
| AC-10 | 部分 | ✅ 實際 POI/證據來源 | 錄影 + 證據連結 |
| AC-11 | 部分 | ✅ 兩裝置 | 雙機錄影 |
| AC-12 | ✅（API 測試） | ✅ 真機邀請連結 | 權限整合測試報告 + 錄影 |
| AC-13 | ✅（並發整合測試） | ✅ 兩裝置 | 測試報告 + 錄影 |
| AC-14 | ✅（注入失敗） | ✅ 飛航模式/不支援區域 | 單元測試 + 錄影 |

### 7.2 失敗情境清單（每項需有對應 UI 與測試）

無網路、弱網路、AI 逾時、AI 輸出不合法、查無店家、路線服務失敗/節流、邀請過期/撤銷、權限不足、STALE 衝突、重複分享、Extension 未登入、App 在背景時收到同步、帳號刪除。

### 7.3 里程碑證據

| 里程碑 | 驗收 | 證據 |
|---|---|---|
| M1 | 模擬器走通流程 1；Route Match 單元測試 | CI 報告、錄影 |
| M2 | 真機 Threads/IG 分享閉環 | 真機錄影、payload 矩陣 |
| M3 | 兩人兩裝置同步 + 權限 | 雙機錄影、權限測試報告 |
| M4 | 流程 3 + AI 助手 | 錄影、AI 評測集結果 |
| M5 | TestFlight + 首爾/廣島實地 | 實地紀錄、問題清單 |

Wireframe 可點擊不算任何 AC 通過；所有 AC 以 iOS App + 真實後端為準。【規格】

---

## 8. 風險清單

| 風險 | 可能性 | 影響 | 緩解 |
|---|---|---|---|
| Apple 在首爾無大眾運輸、步行/開車精度不足 | 高 | 首爾 Route Match 常顯示無法估算 | S1 實測；unknown 狀態；改用步行／開車估算；之後接韓國在地服務 |
| Threads/IG 只給 URL 且 OG 被登入牆擋 | 高 | 分享辨識率低 | 截圖 OCR、手動補填；不承諾自動辨識率 |
| 大眾運輸 ETA 不穩定/不可用 | 中 | detour 數字不可信 | 標註供應商與時間；允許換交通模式 |
| AI 解析準確率不足（時間/分店） | 中 | 確認頁負擔重 | S3 評測；所有歧義強制確認 |
| 路線 API 成本/節流 | 中 | 成本上升、延遲 | 快取、剪枝、base legs 重用 |
| 同步衝突邊界情況 | 中 | 靜默覆蓋 | revision RPC + 並發測試 |
| 商品販售證據過期或錯誤 | 中 | 使用者白跑 | 顯示證據時間、庫存未知、到期重查 |
| App Review（帳號刪除、Sign in with Apple、隱私標籤） | 中 | 上架延遲 | WP11 納入檢查清單 |
| 範圍過大 | 高 | 延期 | 依里程碑交付，M1–M3 優先 |

---

## 9. 下一步

1. ~~回覆第 6 節 D1–D11~~ 已完成（2026-09-24，全部採建議）。
2. S1–S4 與 WP1–WP11 已拆成 GitHub Issues，從 Spike 開始。
