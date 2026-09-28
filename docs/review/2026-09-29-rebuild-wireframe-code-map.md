# 重做版 23 畫面：程式入口與驗收缺口

2026-09-29。本表依本機線框的 23 個畫面名稱與目前 SwiftUI 程式核對；是程式對照，不是 23 屏真機視覺驗收。檔案以 `Packages/AppCore/Sources/Features/` 為相對基準。

| 線框 | 實作入口 | 已有證據／仍需核對 |
|---|---|---|
| 01 旅程・AI 助理 | `TripViews.swift`、`AIResultsView.swift` | 總覽已有待安排、準備摘要及本人回答入口；目前旅程列表到詳情的層級，仍須對照首頁預期與真機操作步數 |
| 02 分享／收集 | `InboxComposeView.swift`、`InboxView.swift`、Share Extension | 無登入／無 Trip 本機保存有 UI 測試；真實 Threads／IG 圖文取得及跨帳號認領仍需實測 |
| 03 匯入文字行程 | `TripViews.swift`、`ImportFlowView.swift` | 文字先行、日期核對；解析失敗重試保留原文有 UI 測試；真實多國樣本待驗證 |
| 04 核對行程草稿 | `ImportFlowView.swift`、AppCore `ConfirmPlaces.swift` | 分店選擇、固定項、原文及草稿候選保存有測試；跨裝置恢復未完成 |
| 05 AI 安排提案 | `TripAIPlanView.swift` | 部分選擇、整日預覽、原子提交、版本與重送有 SQL 證據；真實 AI 及交通可行性未驗收 |
| 06 修改安排 | `StopEditingViews.swift`、`TripAIPlanView.swift` | 人工編輯、AI 非固定站移動／移除與已知時間警示；共用站換店尚需整合 |
| 07 今天 | `TodayView.swift`、`TripStore.swift` | 共用日期、待買與用品摘要；需要真機確認改日／採買後跨頁一致 |
| 08 站點詳情／附近探索 | `TripViews.swift`、`StationExploreSection.swift` | 站點上下文、原子收藏／安排、來源；活動日期與真實附近結果待驗證 |
| 09 雙語計程車卡 | `TaxiCardView.swift`、AppCore `TaxiCard.swift` | 當地語言與中文、原名、地址快取及複製；核心資料有單元測試，真機字級、飛航與各語言待驗收 |
| 10 收藏 | `SavedView.swift` | 個人／共同、來源、單件撤回、原名及地址保護；按鈕互不誤觸與移除流程有 UI 測試 |
| 11 購買清單 | `ShoppingView.swift` | 待安排／已安排／已買、未同步數量；獨立勾選及撤銷有 UI 測試，多人真測待補 |
| 12 商品與部分購買 | `ShoppingQuantityView.swift`、`PersonalPurchasesView.swift` | 分人需求、買家、剩餘量及衝突保留；縮減需求、超買及多人更新需要裝置驗證 |
| 13 必備用品 | `PackingView.swift` | 私人／共同、AI 建議、打包與購買分開、待送；需要完整裝置流程驗收 |
| 14 旅伴與分工 | `MembersView.swift`、`PackingView.swift` | 接任本人接受、退出影響清單與版本阻擋有 SQL 測試；兩帳號 UI 待驗證 |
| 15 旅程列表 | `TripViews.swift` | 預設旅程頁、切換、邀請加入與封存入口；多旅程、登入切換、唯一旅程的入口層級待逐屏確認 |
| 16 已封存旅程 | `TripViews.swift`、AppCore `TripCatalogCache` | 每人手動封存／恢復與帳號隔離快取；過期不自動封存，需飛航／跨裝置驗收 |
| 17 地圖 | `TripMapView.swift` | 與 Today 共享日期；未知座標不假造圖釘。韓國／中國實際可用範圍待測，查店不依賴它 |
| 18 尚未建立旅程 | `RootView.swift`、`TripViews.swift`、`InboxComposeView.swift` | 無 Trip 仍可收件；未登入保存有 UI 測試，登入後完整接續仍待真測 |
| 19 修改衝突 | `TripAIPlanView.swift`、`PackingView.swift`、`ShoppingQuantityView.swift` | 分布於各流程，沒有獨立同名頁；已有版本拒絕與待送保留，需要核對提示、返回及重試是否符合線框 |
| 20 新增／編輯用品 | `PackingView.swift` | 手動名稱、數量、備註、分工與影響確認；改名／增量／換攜帶者重設打包有規則測試 |
| 21 行程範圍內找不到商品 | `ShoppingView.swift`、`ShoppingScheduleView.swift`、`TripAIPlanView.swift` | 顯示無販售線索並保留待買；AI 聖水／弘大反例有測試，真實路線情境待測，非獨立同名頁 |
| 22 針對本站問 AI | `AssistantView.swift`、`StationExploreSection.swift` | 以本站、日期提問；餐飲介紹、來源、路程與外部評分，缺資料保持未知；真實問答品質待驗證 |
| 23 AI 模式與額度 | ShareCore `AIActivityView.swift`、`AccountView.swift`、`RootView.swift` | 明確選模式、API 標示、工作模式固定；後端設定、可用帳號及兩模式真實能力尚未驗收 |

## 下一步的真人檢查順序

先走 18→02→03→04→01→05→07→08→09，核對收件與行程主線；再走 10→11→12→13→20→14，核對共同採買、打包與分工；最後檢查 06／19 的衝突、15／16 的封存與 17／21／22／23 的未知、查詢與模式狀態。

每條流程記錄實際版本、後端版本、裝置、帳號權限與截圖。編譯成功、測試資料、個別 UI 測試與真人驗收分開記錄。
