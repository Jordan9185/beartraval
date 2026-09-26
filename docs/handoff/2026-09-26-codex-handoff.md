# 交接：2026-09-26

給接手的 coding agent（Codex）。工作方式與踩過的坑見 [AGENTS.md](../../AGENTS.md)，產品規則見 [CLAUDE.md](../../CLAUDE.md)。

## 目前狀態

| 項目 | 狀態 |
|---|---|
| 分支 | `claude/github-new-project-v1pk1b`，最新 `64a6a12`（本文件之後的 commit 只有文件） |
| 測試機 | 已安裝 `64a6a12` 的 Release 版（雲端後端） |
| 雲端 DB | migration 套用到 `20260925000018_place_local_address.sql` |
| Edge Functions | `parse-import`、`ask-trip`、`extract-products`、`delete-account`、`invite` 已部署；AI 模型 `claude-sonnet-5` |
| 套件測試 | 本機 `swift test` 145 項全過 |
| CI | DB tests、AI tests 通過；**iOS CI 從 `8d210c8` 起卡住逾時**（見下方 P1） |

## 後續產品方向（本次接手新增）

2026-09-26 的[分享後整理產品提案](../spec/share-inbox-proposal.md)與[開發計畫](../planning/share-inbox-delivery-plan.md)把「分享即收下 → AI 自動整理 → 個人收藏／購物或可編輯行程模板」列為下一階段方向。兩份文件是**提案，尚未取代現行 MVP 規格，也未實作**。分享影片時能否取得畫面／語音仍須真機 payload 驗證；只拿到不可讀 URL 時不能產生虛構地點或行程。

接手順序仍以本文件 P1 的 iOS CI 為合入門檻。新功能工作包 SI-1～SI-6 及影片驗證 SIV 的依賴、契約、驗收證據見開發計畫；正式行程必須由使用者確認、Fixed Stop 不可自動移動。

## 最近完成（2026-09-25）

| Commit | 內容 |
|---|---|
| `6b04396`、`fb44279`、`49b0283` | 2026-09-25 review 的高／中／低嚴重度與視覺風格項目（處理狀態在 [review 文件](../review/2026-09-25-project-review.md) 開頭）；主色熊毛棕（D13） |
| `34c0c3c` | 購物清單新增附照片商品後閃退（SwiftUI 泛型巢狀、Release 堆疊溢位） |
| `0b3c6e9` | 開車／計程車時間、整趟交通方式、收藏貼上分享連結解析 |
| `aa5e187` | AI 改用 Sonnet 5 |
| `8d210c8` | 收藏：截圖裝置上 OCR，自動找店名、地址；韓文地址羅馬拼音後備；找不到時外開 Naver／Kakao／Google |
| `046567f` | 截圖關鍵字與 Apple 地圖店家類型自動帶入收藏類別；辨識中不閃「沒有店名」提醒 |
| `64a6a12` | 見下 |

`64a6a12` 的內容：

- **`ErrorText` 自我遞迴**：從 `fb44279` 起，任何錯誤訊息一出現 App 就閃退。已修正並加回歸測試。
- **當地文字地址**：`places.address_local`（migration 18）。存地點時以韓／日語系反查（`AppCore/LocalAddress.swift`，最多等 4 秒，失敗就不填）。計程車卡片、Naver／Kakao 外開改用 `Place.localAddress`；舊地點打開計程車卡片時即時補查。
- **截圖辨識**：判斷國家（韓文、城市名、中文寫的韓國地址；台灣常用的「の」不算日文）。店名、地址、國家都可編輯。確認後，韓文店名與地址寫進地點的 `name_local`／`address_local`。候選地點再點一次或按「取消選取」可取消，並撤回待確認的 proposal。
- **購物**：
  - 快速新增列選照片後，以 AI 帶入商品名稱。
  - 「從貼文或截圖加入」選照片或分享進來就自動辨識。
  - 辨識失敗會顯示原因。
  - 鍵盤有「完成」鈕，也可以拖動收起。

## 待處理（依優先順序）

### P1：iOS CI 在 `swift test` 卡住，30 分鐘逾時

- **現象**：`gh run list` 顯示 `8d210c8`、`046567f`、`64a6a12` 的 iOS workflow 都被取消。
  - `8d210c8` 那次是被下一個 push 取消的，但已經跑了 23 分鐘，正常只要約 11 分鐘。
  - 卡住的步驟是「Package unit tests (macOS)」：開頭約 30 項測試通過後就沒有輸出，直到逾時。
- **本機狀況**：`swift test` 約 3 秒到 16 秒跑完，全部通過。
- **起點**：`8d210c8` 新增了 `ScreenshotOCRTests`（`Tests/AppCoreTests/PayloadInspectorTests.swift`）。
- **最可能的原因**：
  - 測試用 `NSImage.lockFocus()` 在非主執行緒畫圖。
  - Vision 的 `.accurate` 辨識一次跑三輪，在 CI 虛擬機上可能卡住或極慢。
- **建議做法**：
  1. 改用 `CGContext` 加 CoreText 畫圖，不用 AppKit 的 `lockFocus`。
  2. OCR 測試加 `.timeLimit(.minutes(1))`。
  3. 若 CI 上 Vision 仍不可用，用 `.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)` 只在本機跑，並在測試註解寫明原因。
- **驗證**：push 後 `gh run watch`，確認 iOS workflow 在 15 分鐘內通過，模擬器測試那一步也要跑完。

### P2：需要真機確認（程式已完成，只在模擬器或單元測試驗證過）

1. **購物照片 AI 辨識**：模擬器連本機後端，沒有 AI 服務，拿不到成功結果。雲端 `extract-products` 有部署（不帶資料打會回 400 `INVALID_REQUEST`，路由正常）。請在真機拍商品確認：
   - 名稱有自動帶入。
   - 失敗時畫面有顯示原因。
2. **分享擴充功能裡的截圖 OCR**：Extension 記憶體上限約 120 MB。2048 px 的圖跑三輪 Vision 辨識，沒在真機的 Extension 裡量過。
   - 如果 Extension 被系統終止：改成在 Extension 只辨識一輪（或把圖縮小），或存草稿交給 App 辨識。
3. **中文手機的計程車卡片**：新存的韓國地點應顯示韓文地址。舊地點打開卡片時會連網補查，離線時顯示「地址不是當地文字」提醒。

### P3：已知限制與改善點

- `upsertPlace` 每個地點最多多花 4 秒反查地址（`AppCore/Trip.swift`）。
  - 文字匯入一次確認很多地點時，可能變慢或被 MapKit 節流；反查失敗時不填 `address_local`，不會擋住存檔。
  - 改法：批次時平行查，或匯入時略過、改由計程車卡片補查。
- `LocalAddress.isLocal` 對日本只是粗略判斷：有「區、縣、臺、灣、號」或開頭是「日本」就視為中文寫法。
- 截圖存成「未定位」收藏時，辨識到的地址沒有欄位可存；這類收藏的計程車卡片沒有地址。
- `ScreenshotText.countryHints` 是固定的城市清單，其他國家、城市要自己加。
- 共用地點的殘留風險：某個地圖 ID 第一次被登錄時的名稱由先登錄的人決定（review 文件已記錄）。

### 既有待辦

- 決策 D9「每日以住宿為起訖」尚未實作（[技術規劃 §6](../planning/mvp-technical-plan.md)）。
- [驗收報告](../acceptance/mvp-acceptance.md)「需要人工完成」：TestFlight、兩裝置同框錄影、Naver／Kakao 真機驗證、首爾／廣島實地測試等。

## 最近功能的程式位置

| 功能 | 檔案 |
|---|---|
| 截圖 OCR、店名／地址／國家／類別判斷 | `ShareCore/ScreenshotText.swift` |
| 分享與截圖的收藏流程（可編輯欄位、取消選取、寫入原文名稱與地址） | `ShareCore/ShareFlowView.swift` |
| 收藏新增（相簿選截圖、貼上連結） | `Features/SavedView.swift`（`AddSavedPlaceView`） |
| 當地文字地址 | `AppCore/LocalAddress.swift`、`AppCore/Trip.swift`（`upsertPlace`）、`supabase/migrations/20260925000018_place_local_address.sql` |
| 計程車卡片 | `AppCore/TaxiCard.swift`、`Features/TaxiCardView.swift` |
| 購物照片辨識 | `Features/ShoppingView.swift`（`ShoppingListView.recognizePhoto`）、`ShareCore/ProductImportView.swift`、`AppCore/ProductImport.swift`、`supabase/functions/extract-products`、`ai/product-extract` |
| 附近景點／店家、這附近還有 | `Features/NearbyView.swift`、`AppCore/Navigation.swift` |
| 交通方式比較 | `Features/StopEditingViews.swift`（`LegModesView`）、`AppCore/RouteMatch.swift`（`compareModes`） |

## 接手步驟

1. 讀 `AGENTS.md`、`CLAUDE.md`、本文件。
2. `xcodegen generate && swift test --package-path Packages/AppCore`，確認本機全綠。
3. 先處理 P1，讓 CI 恢復能擋回歸。
4. 動到後端時先 `supabase db push --dry-run`，並確認 migration 對已安裝的舊版 App 相容。
