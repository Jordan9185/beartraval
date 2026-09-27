# iOS AI Travel Companion — MVP 行為規格

版本：0.2 · 2026-09-27（原始基準 2026-09-24）

狀態：【已確認規格】產品定位、收件與安排流程已對齊[現行主軸](ai-first-product-direction.md)；資料模型與歷史選型提問仍是規劃參考。新增驗收 AIJ-01～12 與原 AC-01～14 一併適用，歷史驗收結果不能自動轉用到新流程。

## 0. 參考與現況

- [可互動 HTML wireframe](https://ai-travel-companion-mvp-wireframe.jordan8125.chatgpt.site/)：確認畫面順序與操作意圖。AI、路程、店家、邀請與同步目前都是示意資料；不可把其 JavaScript 實作當成正式架構。
- 主要產品：原生 iOS App。Bottom tabs 固定為 **旅程／今天／地圖／收藏／購物**（Trip / Today / Map / Saved / Shopping；2026-09-25 改為繁體中文介面，店名保留原文並附中文；同日產品負責人決定「旅程」放第一個分頁，原為今天／旅程／…）；辨識整理直接融入收件、清單與草稿，不以聊天入口代替主流程。
- 核心價值：**懶人收集 → AI 辨識整理 → 確認安排 → 旅行使用**。沒有 Trip 也能收集，AI 是整理與建議的核心。
- 必須走通的主流程：
  1. 分享文字／圖片／連結 → 保存來源 → AI 分辨多個地點、商品、行程或混合內容 → 自動整理個人清單／草稿，歧義集中確認。
  2. 既有行程、收藏集合或旅行短句 → 整理／建議安排 → 使用者核對日期、地點與固定事項 → 確認後才建立或更新正式旅程。
  3. 整理結果直接加入旅程 → 可修改、撤回、重新安排 → 今天／地圖共享日期 → 導航、司機卡與完成／撤銷購買。

## 1. 不可妥協的產品規則

1. **正式行程只能由使用者操作後變更。** AI 可提供 proposal，不能自行新增、移動或刪除 Stop。
2. 航班、訂位與使用者標為 Fixed 的 Stop 不可由 AI 移動。時間衝突要明確顯示。
3. 地點不確定時顯示候選分店並要求確認；不能猜一間寫進正式行程。
4. 「順路」表示加入後**增加的旅行時間（detour time）**，不是直線距離。
5. Saved 保存有興趣的地點與其排程關聯；Shopping 保存想買的商品。兩者不可混成同一清單；已安排項目仍可保留來源並顯示日期。
6. 商品「可能販售」與「有庫存」是不同事實。沒有可靠來源時顯示**庫存未知**。
7. 好友新增地點預設進共同 Saved；不直接污染正式行程。
8. 購買完成後，Today 的待買提醒與 Map 上其他備選購買點不再強調；Shopping 保留購買紀錄，旅伴可看到新狀態。

## 2. MVP 範圍

### P0：第一版必須可用

| 模組 | 需求 |
|---|---|
| Trip 建立 | 名稱、日期；辨識主要城市後讓使用者確認；可以稍後邀請旅伴。 |
| 文字匯入 | 貼入 ChatGPT、LINE、備忘錄等文字；辨識日期、時間、Stop、可能地點與 Fixed 候選；保留原文以便校對。 |
| 解析確認 | 每個 Stop 顯示已定位／待確認／資訊不足；分店歧義不得自選。使用者可確認排入待定位文字及地址線索，不參與路線，Fixed 時間約束仍保留。 |
| 正式行程 | 依日顯示 Stop、時間、停留與 Fixed 狀態；使用者確認後建立或修改。 |
| Base Route | 確認地點後產生每日路線；至少支援所選交通方式與行程相鄰停靠點的預估時間。 |
| Today | 首屏能看見今日正式行程摘要、順路收藏數、今天可買商品數、購物進度；詳情向下滑。 |
| Share Extension／AI 整理 | 接收實際可得 URL／文字／圖片；不要求先建 Trip 或分類。自動辨識多項、整理個人清單／草稿，保留來源與狀態；例外才要求補充。 |
| Route Match | 新地點與 Trip 各日 Base Route 比較，顯示最佳日、增加分鐘數與不可行／時間衝突原因。 |
| Saved | All、Eat、Shop、Cafe、Place 篩選；來源、加入者、想去人數；可收藏或由人確認加入行程。 |
| Shopping | 商品新增、尋找可能販售店、按增加時間排序、安排 Purchase Stop、完成勾選、狀態篩選。 |
| Map | 顯示正式路線、Saved、Food、Shopping 圖層；點圖釘可查看地點與 Route Match。 |
| 好友共用 | Trip 層級成員、邀請連結、Owner／Editor／Viewer、共同 Trip／Saved／Shopping；至少在兩部裝置間能同步並在重新連線後收斂。 |
| AI 助手 | 可回答與本 Trip 有關的問題並提出具體修改 proposal；Apply 必須再次由使用者確認。 |

### 暫不列入 P0

- 背景定位、接近店家提醒、完整商品庫存整合、跨平台 Android、完整旅行社交網、消費記帳。
- AI 自動改動正式行程不在範圍。AI 可提出可編輯的整趟草稿與分天建議，正式套用仍需使用者確認。
- 好友免安裝 App 即可完整共同編輯。是否提供**輕量 Web 邀請／預覽頁**列為待決策；iOS 內的共用流程仍為 P0。

## 3. 畫面與狀態

### 3.1 首次使用

兩條起點：`分享／主 App 輸入 → 保存 → AI 整理 → 個人清單／草稿`，或 `建立旅程 → 貼既有行程／描述想法／空白開始`。之後接同一條「確認安排 → 正式旅程 → 旅行使用」。

- 不做多頁 onboarding；沒有 Trip 時仍可收內容與看 AI 整理結果，建立／加入旅程不作為收件前提。
- New Trip 只收旅行名稱、開始／結束日期；城市不強迫預先選，但解析結果需確認。
- Import 允許貼上整段文字或略過。略過時 Trip 是空狀態，不顯示假的 Base Route 或 detour。
- Parsing 顯示明確進度；失敗可重試或回到原文編輯，不丟掉貼上的資料。
- Confirm Places 列出歧義地點、分店、地址／區域與來源證據；Fixed 候選也要讓使用者確認。
- 一個 Stop 無法辨識時，可保留為「待確認文字」，但不可把未知位置拿來計算路線。

### 3.2 Today

- 頂部：Trip、日期／Day、可切換日子。
- 第一視窗：今日正式行程摘要、順路 Saved 數、今天可買數、已買／總數。
- 行程摘要標出 Fixed；點「完整行程」至 Trip。
- 順路 Saved 卡片：來源、加入者、建議日期與 +N 分鐘、加入按鈕。
- 今天可買：只顯示未購買且已安排在當日的商品；勾選立即更新進度。

### 3.3 Trip

- 完整每日時間軸：Stop、時間、停留、交通段、Fixed／Flexible、來源、誰新增。
- Purchase Stop 用較輕的樣式呈現，但屬於已安排的行程停靠點。
- 插入新 Stop 前顯示「原路線 +N 分鐘」與可能的固定時間衝突；按確認後才提交。
- 若行程被另一位旅伴同時修改，不能默默覆蓋；顯示更新後版本並要求重試或重新確認 proposal。

### 3.4 Map

- 圖層：Today Route、Saved、Food、Shopping、Other Days。
- Pin 詳情顯示來源、確認狀態、相對選定日路線的 detour；不可把示意距離當成路線增加時間。
- 商品已購買後，不再強調其備選店。

### 3.5 Saved

- 從分享、手動或好友新增進入。
- 卡片顯示類別、來源 URL、加入者、想去人數、地點確認狀態與最佳日 detour。
- 「想去」只更新偏好；「加入行程」進確認流程。
- 當某地點已加入正式行程，避免同一候選重複出現在待加入 Saved。

### 3.6 Shopping

- 商品名稱必填；網址／圖片／備註可選。新增後先是未安排。
- 尋找販售點顯示「可能販售」的證據、店名與分店，並列出每間／每日 detour；庫存單獨標記。
- 使用者選店安排後建立 Purchase Stop，與商品互相連結。
- 勾選已購買保留購買者與時間；可以撤銷誤勾。

### 3.7 AI 與好友

- AI 問答範例：「今天下午還能塞什麼？」「Amy 收藏哪間順路？」「ReFa 哪天買方便？」
- AI 回答需引用 Trip 內的既定 Stop、Route Match 結果與來源；無資料時回答無法判斷。
- 邀請畫面顯示成員和權限；邀請連結不能用公開 Trip ID 直接取得資料。Viewer 僅讀取；Editor 可新增 Saved／Shopping 並提出或確認正式行程變更；Owner 管理成員與 Trip。

## 4. 核心資料模型（規劃起點）

| 實體 | 必要欄位／關係 |
|---|---|
| Trip | id、name、start/end、time_zone、primary_city、owner_id、revision。 |
| TripMember | trip_id、user_id、role、join_status。 |
| TripDay | id、trip_id、local_date、display_order、route_revision。 |
| Stop | id、day_id、place_id（可空）、raw_label、start_time（可空）、dwell_minutes（可空）、fixed、kind（standard/purchase）、source_id、added_by、sort_order、revision。 |
| Place | id、name、address、coordinate、provider_id、match_status、confidence／evidence。 |
| SourceReference | type（text/URL/image/share）、原始 URL／摘要、加入者、建立時間；保留來源供追溯。 |
| SavedPlace | id、trip_id、place_id／raw_label、category、source_id、added_by、status、想去成員。 |
| ShoppingItem | id、trip_id、name、source_id、added_by、status、planned_store_id、planned_day_id、purchased_by、purchased_at。 |
| MerchantCandidate | item_id、place_id、販售證據、evidence_time、inventory_status（unknown/verified）。 |
| RouteMatch | candidate_place_id、trip_day_id、base_revision、transport_mode、detour_minutes、suggested_position、feasibility、calculated_at。 |
| ChangeProposal | trip_id、目標日、變更內容、依據的 route_revision、status（proposed/confirmed/rejected/stale）、actor。 |

資料模型是討論起點；Claude 應處理時區、重複分享、版本衝突、權限檢查與刪除策略，再決定實體拆分。

## 5. 核心規則與契約

### 5.1 AI 解析契約

輸入：Trip 日期與原始文字。輸出：`days[] → stops[]`，每個 Stop 包含原文片段、日期／時間候選、地點名稱、候選 Place、confidence、是否疑似 Fixed、待確認原因。AI 不輸出「已正式提交」狀態。

管線：文字解析 → Place lookup／去重 → 使用者確認歧義 → 路線計算 → 提交 Trip。地址、營業時間、價格與庫存必須有外部可信來源，不以模型輸出當事實。

### 5.2 Route Match 契約

- 以同一交通模式、同一計算基準，比較「加入候選 Stop 後的旅行時間」與「原 Base Route 旅行時間」。`detour_minutes = max(0, candidate_route_minutes − base_route_minutes)`。
- 對每個可行插入位置計算，選擇不移動 Fixed Stop 且增加時間最少的位置。停留時間、營業時間、固定訂位衝突另外列為**可行性**，不能藏在 detour 數字裡。
- 結果至少包含：Trip Day、候選 Place、最佳插入點、detour、交通模式、Base Route 版本、計算時間、可行性／衝突原因。
- 地點未確認、路線缺資料或路線服務失敗時，回傳 `unknown`／錯誤狀態，不輸出編造的分鐘數。
- 目前只把 MapKit 視為候選。Apple 的 `MKDirections` 提供路線／旅行時間資料，但不同交通模式與地區的能力要先在首爾、廣島實機驗證；尤其 transit 不應先假定與步行／開車相同。[Apple MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections)、[交通模式](https://developer.apple.com/documentation/mapkit/mkdirectionstransporttype)、[路線預估時間](https://developer.apple.com/documentation/mapkit/mkroute/expectedtraveltime)

### 5.3 分享輸入契約

- Share Extension 接收主機 App 提供的 item providers；逐項檢查可用型別並處理 URL、文字或圖片。不能假設 Threads／IG 一定提供完整貼文文字、圖片或 metadata。[Apple NSItemProvider](https://developer.apple.com/documentation/foundation/nsitemprovider)、[Share Extension 支援型別](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)
- 最小閉環：分享即保存 → AI 自動整理 → 結果直接出現在個人清單／草稿 → 必要歧義確認 → 需要時才選 Trip／日期安排。分享當下不要求分類、選 Trip 或等路線。來源不足保留可得內容，補充是後續選用操作。
- App 與 Extension 如需共用本機暫存資料，使用 App Group；正式 Trip 資料仍需以雲端權限和同步機制為準。[Apple App Groups](https://developer.apple.com/documentation/Xcode/configuring-app-groups)

### 5.4 權限與同步契約

- 所有修改由服務端驗證 Trip 成員權限；僅靠 UI 隱藏按鈕不算授權。
- Saved、Shopping 與正式行程變更帶 actor、時間和版本。正式行程提交需檢查 Base Route／Trip revision；過期 proposal 需重新計算或重新確認。
- 同一商品多人想買與「誰買到了」是兩件事；購買完成對旅伴同步，但保留誰原本想買的資料。

## 6. iOS 規劃方向與待驗證決策

### 已定方向

- SwiftUI 原生 App，含 Share Extension；主操作在 iOS，線上 HTML 僅用作 UX 參考。
- 雲端持久化與成員權限屬 MVP，不能只靠本機記憶或單機假同步。
- UI 要提供 loading、空狀態、無網路、解析失敗、找不到店、路線無法計算、邀請失效和同步衝突。

### Claude 需先提出選型與驗證計畫

1. iOS 最低版本、App／Extension 共用模組、導覽和本機快取策略。
2. 後端、身分驗證、Trip 邀請與即時同步方案；權限規則如何在服務端落實。
3. 首爾與廣島的 POI 品質、分店去重、步行／大眾運輸路線可用性與成本；MapKit 是否足夠或需要替代資料源。
4. Threads／IG 實際分享 payload：URL、文字、圖片在真機各能拿到什麼；無法讀完整貼文時的退路。
5. 商品販售證據來源與有效期限；在沒有庫存整合時如何避免虛假「有貨」。
6. 邀請連結是否包含免安裝的輕量 Web 預覽／接受；若做，明確限定其範圍。
7. AI 呼叫架構、費用控制、輸出 schema、可觀測性與資料刪除方式。

## 7. 驗收情境

| ID | Given / When | Then |
|---|---|---|
| AC-01 | 貼入多日行程，包含「XXX Shoes」兩個可能分店 | 必須看到候選；未選前不能寫入已確認 Place。使用者可明確保留為待定位 Stop，不計路線。 |
| AC-02 | 確認分店與 Fixed 訂位後建立 Trip | Today、Trip、Map 使用同一份正式行程；Base Route 有可追溯版本。 |
| AC-03 | 分享一個可辨識 Threads／IG 地點 | 先保存與 AI 整理，沒有 Trip 也能看到個人結果；安排時才選日期，路線可得才顯示 detour，確認後加入。 |
| AC-04 | 分享資料不足或無法取得貼文內容 | 顯示缺少的資訊並允許補填；不得假裝辨識成功。 |
| AC-05 | 候選地點距離近但加入後需繞路 38 分鐘 | 顯示 +38 分鐘，不以直線距離說「順路」。 |
| AC-06 | 最佳日的固定晚餐與候選 Stop 衝突 | 顯示衝突，可收藏或選其他日期；不得移動訂位。 |
| AC-07 | Amy 新增餐廳 | 兩部裝置的共同 Saved 出現該筆；Trip 正式 Stop 不變。 |
| AC-08 | 使用者按「加入行程」 | 先顯示可取得的增量時間與衝突，無法估算則明說；按確認後才新增 Stop。 |
| AC-09 | 新增 ReFa 商品但尚未選店 | Shopping 顯示未安排；Today 不宣稱今天可以買。 |
| AC-10 | 選擇可能販售店 | 顯示店家證據及「庫存未知」；可靠路線可得才顯示 +N 分鐘，未定位可確認建立待定位 Purchase Stop。 |
| AC-11 | 商品標記已購買 | Shopping 進度、Today 待買、Map 備選店與旅伴裝置更新；可撤銷誤勾。 |
| AC-12 | Viewer 使用邀請連結加入 | 能查看共同內容，但無法提交修改；服務端拒絕未授權操作。 |
| AC-13 | 兩位 Editor 同時修改同一天 | 不發生靜默覆蓋；過期 proposal 顯示需重新確認。 |
| AC-14 | 路線服務失敗或地點未知 | 顯示無法估算，不產生虛構 detour。 |

## 8. 交付判定

HTML wireframe 可驗證畫面和點擊路徑，**不能**證明 Share Extension、真實地圖路線、AI 準確率、庫存、雲端同步或 iOS 真機體驗完成。Claude 的規劃應將上列 AC 分成可在模擬器驗證與必須在真機／實際 Threads、IG、網路情境驗證兩類；每個里程碑標明可觀察證據。
