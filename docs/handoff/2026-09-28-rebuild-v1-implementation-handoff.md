# 重做版 V1 — 開發中交接給 Claude

日期：2026-09-28。這是本輪工作目錄的交接，**不是整版完成或驗收證明**。

使用者要求：工作額度低於 15% 停止開發並交接。本文件先持續準備；最近讀值為剩餘 23%（已用 77%，七日工作視窗），仍高於門檻，不能稱為因額度不足停工。每次繼續開發前及重要階段結束時重新查詢；任一可見工作視窗剩餘低於 15% 即停止新增實作，只記錄安全收尾與交接，不把未測試項目標為完成。

## 開始前

1. 讀 `AGENTS.md`、`CLAUDE.md`、`docs/spec/rebuild-v1-spec-draft.md` v0.23、`docs/planning/rebuild-v1-implementation.md`。
2. `git status` 確認現有修改，**保留工作目錄中的後續修改，不重置、不用舊檔覆蓋；本輪提交以 git log 為準**。分支仍為 `claude/github-new-project-v1pk1b`；不開 PR，確認可提交後 commit，push 前 fetch/rebase。
3. 舊正式環境僅有至 migration 36 的紀錄。本輪沒有雲端部署、沒有實際付費 Claude 呼叫、沒有新版 worker 重啟、沒有真機安裝。實際上線狀態應另查，不把本機測試當作正式生效。
4. 23 畫面線框在本機 `/Users/user/.codex/visualizations/2026/09/28/01a0e774-5a71-7eb3-9191-fe4ecf7cf608/beartravel-wireframes.html`；它是示意資料，不是真實 AI／庫存／路程結果。

## 已修改的主要範圍

- `Packing.swift`、`PackingJournal.swift`、`PackingView.swift`：私人／共同用品、打包、分工、AI 選用、手動編輯、離線保存及衝突保留；連結用品採買。
- `Shopping.swift`、`PurchaseJournal.swift`、`ShoppingQuantityView.swift`、`PersonalPurchasesView.swift`、`ShoppingVisitsView.swift`：部分購買、分人需求、採買人、私人採買、離線數量及穩定重送識別。
- `ImportFlowView.swift`、`ConfirmPlaces.swift`、`Itinerary.swift`、`TripViews.swift`：文字先行、原行程忠實解析、確認草稿保存，AI 店名／地址／來源與座標分開；不需要 MapKit 成功才能建立行程。
- `TripAIPlanView.swift`、`SavedScheduleView.swift`、`ShoppingScheduleView.swift`：整趟旅程排日建議、選定部分原子確認、插入位置及非固定站變更預覽、同區域原行程優先、缺候選保留待買。
- `StationExploreSection.swift`、`AssistantView.swift`、`TaxiCardView.swift`、`TaxiAddressCache.swift`：本站附近與問答、來源、路程／外部評分、收藏及安排、地址／店名複製與離線卡片地址。
- `TripStore.swift`、`TodayView.swift`、`TripMapView.swift`：共同日期、Today AI 摘要；`Trip.swift`、`TripViews.swift`：個人手動封存；`Sharing.swift`、`MembersView.swift`：接受接任及退出。
- `ai/shared/tasks.ts` 是兩種 AI 共用的正式派送入口；`ai/personal-worker/src/tasks.ts` 沿用 Codex adapter；`prepare.ts` 擷取原文明示資料；`parse` 正式路徑改忠實 `parseItinerary`，舊 `complete.ts` 全旅程生成仍僅歷史模組。
- `ai/trip-assistant` 擴充本站研究、外部引用驗證、packing_suggestions、shopping_proposal、arrangements；`ai/inbox-organize/src/discover.ts` 不再限韓國。
- `supabase/functions/_shared/{personal-ai,claude-ai}.ts` 與 `personal-ai/index.ts`：模式固定、Cloud 原子領取、用量回報、逾時結案；新增 `prepare-trip`。

## 新增資料遷移（全部尚未部署）

| 編號 | 用途 |
|---|---|
| 37 | 用品與個人封存；RLS、版本、待送操作識別 |
| 38 | AI 偏好、按 provider 領取、暫行 API 工作上限 |
| 39 | 共用購物數量、分人需求、舊購買事件同步 |
| 40 | 私人採買、用品採買關聯、出發前用品禁止排進途中採買站 |
| 41 | prepare 工作種類 |
| 42 | 批次 AI 追加安排、版本、原子交易與重送 receipt |
| 43 | 同店同日多商品共站，不猜合併不同分店 |
| 44 | 暫不安排／恢復；刪站清除所有商品連結 |
| 45 | Claude 中斷後結束原匯入／收件狀態，不重扣 |
| 46 | 無座標 Stop 的原文店名、地址、來源；舊客戶端兼容 |
| 47 | 單件商品撤回；共享站保留；空非固定採買站須由使用者明確選擇移除，預設保留 |
| 48 | 擁有權邀請接受、旅伴退出、未完成分工回待認領 |
| 49 | 私人購買數量重送識別，保留舊四參數呼叫 |
| 50 | 本站候選原子收藏，具地址身份跨次去重；無地址的模糊重複保留待確認 |
| 51 | 同店同日商品重用既有一般站點；店名與完整地址均吻合才合併 |
| 52 | 收藏單獨撤回、保留站點或明確移除無其他用途站；保留地址與固定／共用站，明確解除後不自動重新關聯 |
| 53 | 批次新增可插在原站之前；同位置依選定順序插入，重用站維持原位、錯誤整批回滾 |
| 54 | 明確追加同店到訪及單次撤回；原安排不覆蓋、商品不複製、軟撤回保留重送憑據，Today／AI 上下文認得追加到訪 |
| 55 | 選定非固定站移動／移除；鎖定來源及目標日、核對雙方版本、整批回滾與固定站阻擋 |

## 剩餘工作，建議順序

### P0：先完成現有變更的驗證與修正

- 重新核對本文件後面的測試結果，修正任何未完成／失敗的檢查；不要只看舊日誌的 PASS。
- 核對 AI 回覆能否確實辨識「翻譯店名／近音誤字→原文店家」；路程已要求引用包含本站、候選與路程描述；活動已要求引用日期涵蓋到訪日。分數須有來源支持及平台，缺資料顯示未知。這些保守驗證不取代真實搜尋品質驗收。
- 聖水行程＋只有弘大販售的商品：不得只因有任意 `anchor_stop_id` 就安排弘大。目前 validator 已要求候選及原站點都出現同一具體區域文字，排除僅有城市／國家名稱，已有聖水／弘大反例測試；這仍不等於真實距離、交通時間或固定時段可行性證明。
- 固定行程、日期、當日特殊事件實測。批次已可選插在原站之前並顯示前後位置；既有非固定站移動／移除也已提供，預設不勾選並列來源日、目標日及採買影響；仍未提供完整交通／時間衝突試算、精確指定新時段及全日差異時間軸，不能宣稱完整 AI 重排行程。
- `StationExploreSection` 已改為原子收藏 RPC，具地址候選跨次去重，未知地址的模糊重複回待確認；仍需真機測關頁再開、重送及兩帳號操作。
- 大量匯入站點逐站 AI 搜尋仍序列等待；保留名稱可提早建立，下一步應讓搜尋背景排隊、恢復進度且不重跑已取得結果。

### P1：補齊體驗與生命週期

- 建旅程後已背景要求用品建議，用品頁讀取已保存結果，略過依帳號／旅程／私人或共同範圍記憶；仍需真 AI 驗證。用品改名／改數量已有影響確認，明示只修改用品、購物與購買歷史維持原值；尚不自動同步另一份清單。
- 收藏單獨撤回入口與後端已完成，保留原收藏及固定／共用站，有 11 項 SQL 斷言；商品另一次到訪及單次撤回已實作；SQL 13 項斷言通過，Today 會顯示當次日期而不覆蓋原安排，仍需真機驗收。
- 共同購物主列表已疊加本帳號待送數量並標記尚未同步，暫停舊勾選避免在途衝突；購買事件不捏造。核對已買大於縮減需求的體驗。數量頁已顯示退出成員的歷史需求並要求清除或重新分配，仍需多人真測。
- 封存清單與已看過的詳情已有帳號隔離離線快取，離線詳情不取得編輯權、封存／恢復需連線；需飛航模式驗收。建立／確認草稿跨裝置衝突與恢復；對照全部 23 張線框，補 AI 結果未讀、待確認與準備摘要。
- 退出時列出實際受影響的未完成物品；私人用品退出後的歷史入口；刪 Trip 目前 FK 會刪用品，若採 R4 私人歷史保留建議需另立資料策略，不能宣稱已做到。
- `R1–R5` 仍有「建議」而非逐項已採用的細節；不要自行宣稱全數已確認。R6 已延到第二版。

### P1：雙 AI 上線前

- 由擁有者在後端安全設定提供 `ANTHROPIC_API_KEY` 與明確的 `CLAUDE_AI_MODEL`，**不要將 key 放 App、repo、交接或對話**。
- 沿用 `PERSONAL_AI_ALLOWED_USER_IDS` 白名單；新旅伴目前不會因接受 Trip 邀請就自動獲得 AI 使用權。補管理可用帳號／每人限額／總額度設定；暫行 20／100 工作不是金額預算。
- 管理摘要、費用估算、等待工作明確轉 Claude 並防雙重執行尚未做。偏好切換目前只作用於新工作，這是刻意避免重扣。
- 六種任務 prepare／parse／ask／extract／inbox／discover，在本機 GPT 與 Claude 各做一筆受控測試，包含圖片及搜尋；來源與金額未知不得填零。
- Cloud 環境中斷、排隊未啟動、取消／重送、Mac 離線、額度不足、帳號撤權及 lease 競態實測。整體 wall time 與 Edge 背景時間限制須核對。

### 上線與真人驗收

1. 先完整本機測試與 Release build，處理代碼審查發現。
2. 說明 migration 影響；`supabase db push --dry-run` 確認後再套用，部署七個 AI Edge 入口，更新 Mac worker bundle；不可只更新 App。
3. 真機 Release／至少兩帳號測：貼行程→確認店→Today；分享→個人來源→共同收藏；採買不跨區、部分購買、用品、附近問答、雙語卡、飛航模式、封存、接任與退出。
4. 用實際結果分別記錄〔已開發／待實測〕、〔已部署〕、〔已驗收〕。不要用本機單元測試取代真人接受。

## 本輪驗證記錄（執行中持續更新）

- Swift：188 tests / 49 suites 通過；13 個需要外部後端／真實整合的測試依既有條件略過。
- AI：itinerary-parse 37、trip-assistant 23、product-extract 6、inbox-organize 20、personal-worker 17 測試通過；assistant typecheck、worker bundle 通過。
- SQL：包含新 migration 至 55 的本機整批測試通過（29 組 SQL 測試及 4 組並行測試）；重點新增用品、模式隔離、數量、原子安排、無座標目的地、Cloud 逾時、共站撤回、擁有權接受退出；並有四個既有並行測試。
- 七個 Edge 入口 Deno 型別檢查曾通過；後續修改仍需最後重跑。
- iOS Simulator Release build 已通過收藏撤回、插入位置及購物數量待送版本；封存快取、用品影響確認與同店再訪版本也已通過；既有站移動／移除與拆分確認列後的最新 Release 編譯亦通過。worker bundle 已重新建置。這不是實體裝置驗證。
- 新版 AI 匯入兩項模擬器 UI 測試通過：分店必須選擇後才能提交、解析失敗重試保留原文；fixture 同時要求無座標目的地保留地址。結果包：`build/RebuildUITests/Logs/Test/Test-BearTravel-2026.09.28_21-42-37-+0800.xcresult`。完整 16 項 UI 回歸正在追加執行；真機與真 AI 沒有執行。
- 詳細本機日誌位於 `/tmp/beartravel-rebuild-*.log`；為暫存檔，不依賴它們永久存在。

## 此次接續新增驗證

- `unschedule_saved`：11 項斷言，權限、版本、重送、保留原站、再次安排、共用採買與地址。
- `arrangement_position`：7 項斷言，跨日錨點整批回滾、順序、固定時段、重送、多商品共站及固定收藏保留。
- Swift 新增購物待送顯示與封存快取帳號隔離測試；AI 新增錯誤路程起點／分鐘及過期活動反例。

- `extra_shopping_visits`：13 項斷言，權限、來源、重送、已撤回工作不復活、原站保留、共用用途及固定站保留。
- `arrangement_changes`：9 項斷言，來源日版本、跨日移動、原時間保留、重送、固定站拒絕、整批回滾與重複操作拒絕。
- Swift 總數增加至 188；AI assistant 總數增加至 23，包含引用被剔除後不保留原答案中的錯誤分鐘與活動，以及固定站變更拒絕。
