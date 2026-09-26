# Travel Inbox 實作交接：2026-09-26

本文件接續[原交接](2026-09-26-codex-handoff.md)與[分享後整理開發計畫](../planning/share-inbox-delivery-plan.md)。程式、CI 與後端部署狀態分開記錄；雲端已部署不等於真機驗收或 App 已發布。

## 已實作

- Share Extension 改成分享後自動保存，不要求選地點／商品／旅程。正式 loader 保留完整文字、URL 與實際取得的多張圖片／影片檔；檔案在 `NSItemProvider` callback 內複製到 App Group，再以資料夾原子提交。只有來源內容確實保存才顯示成功。已登入時，最多三張圖片或純文字／連結會在分享面板內嘗試快速同步；失敗保留本機，主 App 登入或恢復連線後重送。未登入來源需一次確認帳號歸屬。
- `20260926000019_travel_inbox.sql` 建立 owner-only 收件、附件、個人項目、無日期模板與分析工作狀態，重複 URL／內容冪等，私有圖片 bucket。AI 工作以 attempt 保護，過期工作不能覆寫新結果；單項更正／撤銷有 revision。帳號刪除清理私有圖片與 App Group 中屬於該帳號的來源。
- `organize-inbox` Edge Function 使用 Sonnet 5 從實際取得的文字與至多十張縮圖抽取多項地點／商品及行程模板。輸出必須有可回查的原文片段或圖片序號；只有明確、來源可錨定且未落在「不要去／避雷」等否定語境的文字項目自動進個人清單。未定位地點不能參與路線，商品不宣稱庫存。
- 主 App「旅程 → 更多 → 分享收件匣」可查看來源、狀態、失敗原因與候選；「收藏／購物」各有個人清單入口。使用者可更正、撤銷、確認 MapKit 地點，也可明確選旅程後發布到旅伴共同清單。App 對唯一且明確相符的 POI 嘗試自動定位；分店歧義保留待確認。
- 行程模板可編輯名稱、天數、停靠點和順序。套用前顯示新增項目、未定位與既有 Fixed Stop 數量；按「確認套用」才以伺服器 RPC 原子建立新 Trip 或追加既有 Trip，檢查模板與每日 route revision。新項目先為待定位文字，不會移動原有 Fixed Stop 或編造路線分鐘數。
- CI 的 macOS OCR 整合測試在無畫面 runner 跳過，保留本機／裝置測試；避免佔滿 iOS CI 的 30 分鐘。

## 驗證狀態

- 本機 `CI=1 swift test --package-path Packages/AppCore`：147 項通過，OCR 裝置測試跳過。
- 本機 `xcodegen generate` 與 iPhone 17 Pro 模擬器 Debug build：通過。
- 文字／圖片首批版 `xcodegen generate`、無簽章 iOS Release build、使用本機 Team ID 的簽章封存與 `codesign --verify --deep --strict`：通過；產出的 Share Extension 啟用規則只有網址、文字、最多十張圖片，沒有純影片檔入口。收件詳情會自動輪詢整理結果，失敗時以可理解的訊息提供重試。
- `ai/inbox-organize` TypeScript typecheck 與 4 項來源錨點／歧義／否定語境測試：通過；`organize-inbox`、`delete-account` Deno typecheck：通過。
- Postgres 17 測試：既有 suite 全過，Travel Inbox 24 項斷言通過（owner 隔離、URL 去重、重送、更正與模板套用）。
- CI：最終程式 commit `def0c5e` 的 [iOS run 36219655446](https://github.com/Jordan9185/beartraval/actions/runs/36219655446) 通過套件與模擬器測試；同一功能版本的 [AI run 36219263373](https://github.com/Jordan9185/beartraval/actions/runs/36219263373) 與 [DB run 36219263368](https://github.com/Jordan9185/beartraval/actions/runs/36219263368) 通過。`def0c5e` 只補了本機暫存資料夾過濾與對應測試。
- 雲端：`20260926000019`～`20260926000022` 已套用；`organize-inbox` 與更新後的 `delete-account` 已部署且啟用 JWT 驗證。`21` 補背景工作讀取圖片紀錄的權限，`22` 讓 AI 額度紀錄接受 `inbox` 類型；雲端測試實際發現並修復這兩個缺口。
- 兩個臨時帳號的雲端測試通過：文字加圖片得到 4 個候選、1 份模板；純圖片行程得到 2 個候選、1 份模板，圖片候選保持待確認。另驗證 owner-only 原文／候選／模板、明確確認後套用新 Trip、未定位停靠點、相同操作重送不重複建立。兩輪臨時帳號與資料均已刪除。
- 社群 App 實際分享 payload、真機操作與 TestFlight：**尚未驗證／完成**。本機已設定 Team ID 並產出可驗證的簽章封存，但 App Store Connect 匯出回覆 `No Accounts`，主 App 與分享擴充功能都缺少發佈用描述檔；需要在 Xcode 登入具發佈權限的 Apple 帳號或提供 App Store Connect 簽章設定。已連接的 iPhone 在本輪編譯時處於鎖定狀態。

## 尚需驗證與限制

1. 影片：分享擴充功能可保存實際提供的影片檔與 URL；本輪未開啟抽影格、OCR、語音轉錄和時間碼分析。只有不可讀影片連結時會保存來源並標資訊不足。需先完成 Threads／IG／相簿真機 payload 矩陣與品質、記憶體和處理時間測試。
   文字／圖片首批版已移除純影片檔的 Share Extension 入口；社群提供的影片連結仍可當來源收件，不會冒稱已讀取影片內容。
2. 大型附件或超過三張圖片：需在主 App 開啟後同步；十張圖片可送 AI，取得失敗的附件會在收件詳情標明。影片原檔目前留在 App Group，尚無自動清理期限；刪除帳號會清理。
3. 無 Trip 也可先保存並整理；正式 Trip 套用需使用者確認。未定位地點不能算 Route Match；模板整組最佳日優化與影片行程自動拆天待後續工作。
4. 個人清單目前以來源項目顯示。跨不同貼文的同店推薦次數、商品型號級實體去重與雲端多裝置影片原檔尚未完成。
5. 雲端收件隔離、AI 整理與新 Trip 模板套用已用臨時帳號驗證；個人／共同清單的真機流程仍待驗。首批版還需簽章、裝置解鎖、Threads／IG／相簿的文字及圖片分享 payload 與操作證據，才能交付 TestFlight。影片可得性、記憶體與延遲留到影片階段；完成 App 發布前不能宣稱正式使用者可用。

## 2026-09-26 下午增補：分享品質與真機試用

- 收藏與購物分頁直接顯示個人 AI 項目、待確認候選和最近分享狀態，避免分享後只看見空的旅伴清單。明確圖片名稱可進個人清單；只有料理加地區時保留成候選，不冒充已定位餐廳。
- Threads 公開短連結在限定網域內讀取 Open Graph 摘要，與原始分享 payload 分欄保存。使用者提供的 `https://www.threads.com/share/_77GV9nCg/` 以本機實際請求讀到「無垢屋」摘要；解析器補上跨行 HTML 屬性處理。舊的 `insufficient` 收件可手動重新整理。
- 未定位收藏可查有網頁來源的餐廳名稱，再用 MapKit 找定位點並由使用者確認；AI 與網頁都不提供座標。購物項目把來源明示的店名保留成線索，與行程中已定位店家比對，UI 區分「可詢問」與有既存販售證據的「可能販售」，庫存仍未知。
- 雲端已套用 migration `20260926000023`～`20260926000025`，已部署 `organize-inbox`、`discover-places`、`extract-products`。本機 Swift 套件測試、兩個 AI 模組測試與型別檢查已通過；SQL 測試環境缺 `initdb`、`psql`，本輪未在本機重跑。
- 已以 Release 簽章 build 安裝到 `Jordan 的 iPhone`，使用者正在協助實測。尚無 Threads／相簿從社群 App 分享的實機結果、網頁搜尋候選品質或購物店名比對的人工驗收；任何缺口以裝置回報續修。此次為直接安裝試用，不是 TestFlight 發布。

### 實機回報後修正

- 使用者指出「收藏 → 從截圖辨識」仍只有 OCR 與 Apple 地圖候選，無垢屋人參雞找不到正確韓國地點，外開入口也只見 Google。已將這條既有 `ShareFlowView` 路徑接到有來源的韓國店家搜尋：辨識後自動列韓文店名、可核對的韓文地址、Naver／Kakao 及來源；Apple 地圖結果降為行程定位候選。找不到定位點時仍可看店名與地址線索，不能編造座標。
- 個人收藏中的未定位來源也會自動搜尋並保存最多三個候選。`20260926000026` 已套用，`discover-places` 已重新部署；本機 Swift 套件 151 項與 AI 14 項測試通過。新 App 畫面仍須再次 Release 建置、覆蓋安裝，並讓使用者實測這張無垢屋截圖的搜尋品質與在地地圖跳轉。
