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
- `ai/inbox-organize` TypeScript typecheck 與 4 項來源錨點／歧義／否定語境測試：通過；`organize-inbox`、`delete-account` Deno typecheck：通過。
- Postgres 17 測試：既有 suite 全過，Travel Inbox 24 項斷言通過（owner 隔離、URL 去重、重送、更正與模板套用）。
- CI：最終程式 commit `def0c5e` 的 [iOS run 36219655446](https://github.com/Jordan9185/beartraval/actions/runs/36219655446) 通過套件與模擬器測試；同一功能版本的 [AI run 36219263373](https://github.com/Jordan9185/beartraval/actions/runs/36219263373) 與 [DB run 36219263368](https://github.com/Jordan9185/beartraval/actions/runs/36219263368) 通過。`def0c5e` 只補了本機暫存資料夾過濾與對應測試。
- 雲端：`20260926000019`、`20260926000020` 已套用；`organize-inbox` 與更新後的 `delete-account` 顯示 ACTIVE 且啟用 JWT 驗證。未登入呼叫 `organize-inbox` 回 401。雲端兩帳號資料隔離、實際 AI 輸出、社群分享 payload、真機使用流程與 App 發布：**尚未驗證**。

## 尚需驗證與限制

1. 影片：分享擴充功能可保存實際提供的影片檔與 URL；本輪未開啟抽影格、OCR、語音轉錄和時間碼分析。只有不可讀影片連結時會保存來源並標資訊不足。需先完成 Threads／IG／相簿真機 payload 矩陣與品質、記憶體和處理時間測試。
2. 大型附件或超過三張圖片：需在主 App 開啟後同步；十張圖片可送 AI，取得失敗的附件會在收件詳情標明。影片原檔目前留在 App Group，尚無自動清理期限；刪除帳號會清理。
3. 無 Trip 也可先保存並整理；正式 Trip 套用需使用者確認。未定位地點不能算 Route Match；模板整組最佳日優化與影片行程自動拆天待後續工作。
4. 個人清單目前以來源項目顯示。跨不同貼文的同店推薦次數、商品型號級實體去重與雲端多裝置影片原檔尚未完成。
5. 下階段需要以兩個測試帳號驗證雲端來源隔離、AI 整理、個人／共同清單與模板套用；再收集 Threads／IG／相簿真機 payload 與操作證據，確認影片可得性和記憶體、延遲。完成這些驗證及 App 發布後，才可宣稱正式使用者可用。
