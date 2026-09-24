# S2 分享 payload 矩陣（Threads／IG）

對應 issue #2、規劃 §5。狀態：**工具完成，真機資料待收集**。

## 工具

- Share Extension（DEBUG 期間即 Payload Inspector）：接受所有型別，對每個 `NSItemProvider` 的每個 `registeredTypeIdentifiers` 載入一次，記錄實際回傳類別、截斷預覽（500 字）、大小、耗時；影音與圖片只讀檔案大小，不載入記憶體。
- 分享時可填「來源標籤」（例如 `Threads 單圖`），按「記錄」寫入 App Group。
- App：Today 右上角 🐞 → Payload Inspector → 右上匯出 JSON（AirDrop／存檔案）。

## 測試步驟（真機）

1. 在 `Config/Local.xcconfig.local` 填 `DEVELOPMENT_TEAM`（與需要時的 `BUNDLE_ID_PREFIX`），`xcodegen generate` 後以 Xcode 裝到 iPhone。
2. 在各來源 App 依下表操作「分享 → BearTravel」，來源標籤照表格第一欄填寫。
3. 另外測一次「複製連結」後貼到 App（WP6 手動輸入的退路），不需記錄。
4. 全部完成後匯出 JSON，放到 `docs/research/data/share-payloads-<日期>.json`，並把結果填進下表。

## 環境

| 項目 | 值 |
|---|---|
| iPhone 型號／iOS | 待填 |
| Threads 版本 | 待填 |
| Instagram 版本 | 待填 |
| 測試日期 | 待填 |

## 矩陣

「型別」填 `registeredTypeIdentifiers`；「可用內容」填實際拿到的 URL／文字／圖片檔案；「地點資訊」指是否含店名、地址或座標。

| 來源標籤 | 型別 | 可用內容 | 地點資訊 | 退路建議 |
|---|---|---|---|---|
| Threads 純文字 | | | | |
| Threads 單圖 | | | | |
| Threads 多圖 | | | | |
| Threads 影片 | | | | |
| Threads 地點標籤 | | | | |
| IG 貼文單圖 | | | | |
| IG 輪播 | | | | |
| IG Reels | | | | |
| IG 含地點貼文 | | | | |
| IG 地點頁 | | | | |
| IG 限動 | | | | |
| Safari（對照） | `public.url` | URL；`attributedContentText` 為頁面標題 | 無 | — |
| Google Maps（對照） | | | | |
| Apple Maps（對照） | | | | |
| Naver Map（對照） | | | | |
| Kakao Map（對照） | | | | |

Safari 列為 2026-09-24 在 iOS 26.5 模擬器的結果（`https://www.apple.com/tw/maps/`，標題「地圖 - Apple (台灣)」，4 ms），用來確認工具本身運作正常；真機需重測。

## 退路驗證（§5.2）

| 退路 | 驗證方式 | 結果 |
|---|---|---|
| URL → Open Graph | 對上表取得的 Threads／IG URL 以未登入狀態抓 `og:title`／`og:description`；遇登入牆記為失敗，不嘗試繞過 | 待填 |
| 截圖 → Vision OCR | 對 IG／Threads 截圖跑 `VNRecognizeTextRequest`（繁中／韓／日），記錄店名是否可讀 | 待填 |
| 地圖連結座標解析 | Google／Apple／Naver／Kakao 分享連結是否含座標，或需展開短網址 | 待填 |
