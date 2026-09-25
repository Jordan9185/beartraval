# MVP 驗收報告（WP11）

對應 issue #15、規劃 §7。日期：2026-09-24（證據數量 2026-09-25 依 review 後的測試重新計算）。

**判定原則**（規劃 §7）：所有 AC 以 iOS App + 真實後端為準，Wireframe 不算。下表把「自動化／模擬器」與「真機／實地」分開；只有兩欄都完成才算通過。

**狀態圖例**：✅ 已完成並有證據　⏳ 需真機、兩台裝置或實地，尚未做　⚠️ 部分完成

## 證據來源

| 代號 | 內容 | 執行方式 |
|---|---|---|
| SQL | `supabase/tests/*.test.sql`：11 組、239 項斷言，另含 3 個兩連線同時寫入的測試（同日提交、同時確認 proposal、同時收藏同一地點） | `supabase/tests/run.sh`（CI：DB tests，PostgreSQL 17） |
| UT | `Packages/AppCore` 單元測試 124 項 | `swift test --package-path Packages/AppCore`（CI：iOS） |
| IT | 對本機 Supabase 的整合測試 9 組（多帳號、Realtime、Edge Functions） | 見 `supabase/README.md`「iOS 整合測試」 |
| UI | XCUITest 3 項（匯入 2、Shopping 1），iOS 26.5 模擬器 | BearTravel scheme Test（CI：iOS） |
| MK | 真 MapKit 路線測試（首爾／廣島） | `BEARTRAVEL_TEST_MAPKIT=1 swift test` |
| AI | 單元測試：`ai/itinerary-parse` 20 項、`ai/trip-assistant` 14 項、`ai/product-extract` 5 項；前兩者另有 eval dry-run（評分器自我檢查，不通過即失敗）；Edge Functions 以 `deno check` 型別檢查 | CI：AI tests；真實 eval 需 API key |
| SIM | 模擬器手動操作（截圖在對話紀錄中） | — |

## AC 逐條

| AC | 情境 | 自動化／模擬器 | 真機／實地 | 狀態 |
|---|---|---|---|---|
| AC-01 | 貼入多日行程，「XXX Shoes」兩個可能分店 | UI `testAmbiguousBranchMustBeChosenBeforeSubmit`：兩個分店都列出、不自動選，未選前「建立 Trip」按不下去；UT `ConfirmPlacesTests`；SQL `imports`（未選分店存為待確認文字） | 真實 AI 解析需 API key（S3 eval 尚未跑） | ⚠️ |
| AC-02 | 確認分店與 Fixed 訂位後建立 Trip | IT `importKeepsTextThroughFailedParseAndCommits`、`snapshotMatchesServerRevision`；Today／Map 共用 `TripStore` 的 `TripSnapshot` 並顯示資料版本 r#；旅程分頁另行載入 days／stops（收到變更時重新整理），尚未與 snapshot 做同版本比對；Base Route 綁 route_revision | 三頁截圖對照（需登入後操作） | ⚠️ |
| AC-03 | 分享可辨識的 Threads／IG 地點 | UT `ShareAnalysisTests`；SIM：Safari 分享走完 Extension 流程；IT `friendSaveGoesToSharedSavedAndReshareDedupes` | 真機 Threads／IG 錄影、payload 矩陣 | ⏳ |
| AC-04 | 分享資料不足 | UT：只有連結時列出「拿不到貼文內容」「沒有可搜尋的店名」；未確認地點可先收藏並補填（SQL `saved`） | 真機錄影 | ⏳ |
| AC-05 | 距離近但需繞路 38 分 | UT `detourIsAddedTravelTimeAtBestMiddlePosition` 等；S1 報告 §2「直線近但需繞路」10 組實測（例：漢江兩岸 1.9 km → 步行 31.9 分） | 首爾／廣島實地 | ⚠️ |
| AC-06 | 最佳日的固定晚餐與候選衝突 | UT `fixedConflictIsReportedSeparatelyAndFeasiblePositionPreferred`（遲到 35 分，改選無衝突位置）；確認頁分開顯示路程／停留／固定行程 | UI 錄影 | ⚠️ |
| AC-07 | Amy 新增餐廳 | IT `realtimePushAndCatchUp`：另一台收到 Realtime 通知、正式 Stop 不變；SQL `saved` | 兩裝置同框錄影 | ⏳ |
| AC-08 | 按「加入行程」 | IT `twoEditorsSecondGetsStaleAndReconfirms`；SQL `proposals`（提出不寫入，確認才寫入）；UT `proposeShowsNumbersWithoutWriting` | — | ✅ |
| AC-09 | 新增 ReFa 尚未選店 | UI `testAddPurchaseAndUndo`（顯示未安排）；UT `todayOnlyScheduledUnpurchasedForThatDay`；IT `purchaseStopAndSyncedPurchase` | — | ✅ |
| AC-10 | 選擇可能販售店 | IT：證據、30 天到期、庫存 unknown、確認後有 Purchase Stop；SQL `shopping` | 實際 POI／官方店鋪頁證據錄影 | ⚠️ |
| AC-11 | 商品標記已購買 | UI：進度更新、可撤銷；IT：旅伴裝置收到並看到已購買、Owner 可撤銷；UT：Map 備選店降權 | 兩裝置錄影 | ⚠️ |
| AC-12 | Viewer 用邀請連結加入 | IT：Viewer／Editor 直接呼叫 API 越權被拒；SQL `permissions` 34 項、`sharing` 18 項；邀請預覽頁不含行程內容 | 真機點邀請連結 | ⚠️ |
| AC-13 | 兩位 Editor 同時修改同一天 | SQL 兩連線同時寫入 2 項；IT `twoEditorsSecondGetsStaleAndReconfirms`（第二位拿到重新計算結果、必須再確認） | 兩裝置錄影 | ⚠️ |
| AC-14 | 路線失敗或地點未知 | UT：韓國大眾運輸不送請求、任一段算不出不給數字、未確認地點不參與；MK：首爾大眾運輸回無法估算；錯誤訊息不含數字 | 飛航模式／實地 | ⚠️ |

## 失敗情境（規劃 §7.2）

| 情境 | UI | 測試 |
|---|---|---|
| 無網路 | 頂部離線提示；Today／Map 顯示最近一次快取並標時間；收藏想去、購買排入佇列 | UT `OfflineQueueTests`、`snapshotCacheRoundTrips` |
| 弱網路 | 同上；Realtime 漏送時每 30 秒補拉 | IT `realtimePushAndCatchUp`（重新連線補拉） |
| AI 逾時／輸出不合法 | 匯入失敗頁（重試／編輯原文／略過）；助手顯示「暫時無法回答」 | UI `testParseFailureRetryKeepsRawText`；AI validator 測試 |
| 查無店家 | 「找不到符合的地點」＋手動輸入或保留待確認 | Confirm Places、Share flow |
| 路線服務失敗／節流 | 「無法估算」／「路線服務忙碌」，不顯示分鐘 | UT `unavailableReasonsNeverShowMinutes`；Telemetry 記錄失敗原因 |
| 邀請過期／撤銷 | 加入畫面與預覽頁說明，請擁有者重發 | SQL `permissions`、`sharing` |
| 權限不足 | Viewer 隱藏寫入按鈕；伺服器仍拒絕 | IT（AC-12） |
| STALE 衝突 | 重新計算並要求再確認 | SQL、IT（AC-13） |
| 重複分享 | 回傳既有項目並標記想去 | SQL `saved`、IT |
| Extension 未登入 | 存草稿，App 的 Saved 分頁繼續 | SIM：草稿寫入 App Group |
| App 在背景時收到同步 | 回到前景時重新訂閱並補拉 | IT（補拉） |
| 帳號刪除 | 設定 → 刪除帳號；Trip 轉移或刪除，協作紀錄匿名化 | SQL `deletion`、IT `deleteAccountTransfersSharedTrip` |

## 刪除、隱私與 App Review

- 刪除 Trip（Owner）：連同匯入原文、AI 問答一起刪除（D11）。SQL `deletion`。
- 刪除帳號（App 內「設定」）：`delete-account` Edge Function；擁有的 Trip 轉給資歷最久的 Editor，沒有其他成員則刪除；旅伴仍看得到共同內容，作者顯示為「已刪除帳號的成員」。
- 墓碑：軟刪除的 Stop 與移除的 Saved 30 天後清除（pg_cron 每日 03:17）。
- 隱私清單：App 與 Extension 皆附 `PrivacyInfo.xcprivacy`（Email、名稱、使用者內容；不追蹤；UserDefaults CA92.1）。
- App Store Connect 的隱私標籤需依上述內容填寫。⏳

## 可觀測性

- 路線：`InstrumentedProvider` 記錄每種交通方式的延遲 p50／p95 與失敗原因；App 內 Debug →「路線／AI 呼叫統計」，並寫入 `os.Logger`（subsystem `beartravel`）。
- AI：`parse-import`、`ask-trip` 每次呼叫寫一行 JSON 日誌：延遲（`ms`／`latency_ms`）、`input_tokens`／`output_tokens`、狀態（不記 prompt 與原文，D11）；App 端也記錄 `ai.ask` 延遲。
- 成本：日誌有 token 數；換算金額需依當時的模型價格表，尚未自動化。⏳

## 需要人工完成

| 項目 | 需要 |
|---|---|
| 真機簽章、TestFlight | Team ID、App Store Connect |
| 雲端 Supabase | Project URL、anon key、`supabase link`、`supabase db push`、`supabase functions deploy` |
| AI 解析與助手的真實 eval | `ANTHROPIC_API_KEY`（`npm run eval`，會產生費用） |
| Threads／IG payload 真機重測 | 真機 + `docs/research/share-payload-matrix.md` |
| Naver／Kakao 外開真機驗證 | 真機安裝兩個 App |
| 兩裝置同框錄影（AC-07、11、12、13） | 兩台裝置、兩個帳號 |
| 首爾／廣島實地 3 天 | M5 |
| 路線參考值與誤差 | S1 報告 §2 |
| Universal Link | 網域 + apple-app-site-association；目前用 `beartravel://invite` |
