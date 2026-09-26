# AGENTS.md

給 Codex 等 coding agent 的工作說明。人類開發者看 [README.md](README.md)。

## 開始前先讀

1. [CLAUDE.md](CLAUDE.md)：**不可違反的產品規則**、UI 慣例、畫面設計原則、已確認技術決策。全部適用，以它為準。
2. [docs/handoff/](docs/handoff/) 最新一份：目前狀態、未驗證項目、已知問題、下一步。
3. 動到對應功能時再讀：規格 [docs/spec/](docs/spec/)、技術規劃 [docs/planning/mvp-technical-plan.md](docs/planning/mvp-technical-plan.md)（決策 D1–D13）、後端 [supabase/README.md](supabase/README.md)（RPC、權限、錯誤代碼）。

## 慣例

- 文件、UI 字串、程式註解都用**繁體中文**；commit message 用英文（看 `git log` 的寫法：一句標題，內文條列）。
- 分支 `claude/github-new-project-v1pk1b`。專案擁有者的做法是**不開 PR，直接 commit 後 push**；push 前先 `git fetch` 並 rebase。
- 沿用周邊程式的寫法與註解密度；同一種物件（Stop、Saved、商品、detour 分鐘）用同一個元件（`ShareCore/BrandColor.swift` 的 `PlaceSearchField`、`PlaceOptionRow`、`ErrorText` 等）。
- 秘密不進版控：`Config/*.xcconfig.local`、`supabase/functions/.env` 都已 gitignore。**不要**把 API key、anon key、密碼寫進程式、文件或對話；repo 是公開的。
- 不要在 App 或網頁裡代替使用者輸入密碼、建立帳號。

## 結構

| 路徑 | 內容 |
|---|---|
| `App/`、`ShareExtension/`、`UITests/` | App target、分享擴充功能、UI 測試 |
| `Packages/AppCore/Sources/AppCore` | Domain、規則、後端呼叫（Supabase、MapKit） |
| `Packages/AppCore/Sources/Features` | SwiftUI 頁面（旅程／今天／地圖／收藏／購物） |
| `Packages/AppCore/Sources/ShareCore` | 分享流程（App 與 Extension 共用）、截圖文字辨識、共用元件 |
| `supabase/migrations`、`supabase/tests`、`supabase/functions` | DB migration、SQL 測試、Edge Functions |
| `ai/itinerary-parse`、`ai/trip-assistant`、`ai/product-extract` | Claude 呼叫（行程解析、AI 助手、商品辨識），Edge Function 直接 import |
| `project.yml` | XcodeGen 設定；`.xcodeproj` 由它產生 |

## 指令

```bash
# 產生 Xcode 專案（改過 project.yml 或新增檔案後）
xcodegen generate

# 套件單元測試（macOS，最快；改 AppCore/Features/ShareCore 後必跑）
swift test --package-path Packages/AppCore

# 模擬器 build（Debug）
xcodebuild -project BearTravel.xcodeproj -scheme BearTravel \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DerivedData build

# 真機 Release build 與安裝（需要 Config/Cloud.xcconfig.local 與簽章設定）
xcodebuild -project BearTravel.xcodeproj -scheme BearTravel -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Device -allowProvisioningUpdates build
xcrun devicectl list devices
xcrun devicectl device install app --device <UDID> build/Device/Build/Products/Release-iphoneos/BearTravel.app

# AI 模組測試（各自目錄）
cd ai/product-extract && npm test

# DB 測試（需要 Postgres 16+ 的 initdb/pg_ctl/psql；本機沒有時看 CI 的 DB tests）
supabase/tests/run.sh
```

CI（`.github/workflows/`）：`ios.yml`（swift test + 模擬器測試，30 分鐘上限）、`db-tests.yml`、`ai-tests.yml`。用 `gh run list` 看結果。

## 環境

| Build | 後端 | 備註 |
|---|---|---|
| Debug（模擬器） | `Config/Base.xcconfig` → 本機 `supabase start`（`127.0.0.1:54321`） | 本機沒跑 `supabase functions serve` 時，AI 功能（解析、助手、商品辨識）會回 404，這是環境問題不是 bug |
| Release（真機） | `Config/Cloud.xcconfig.local` → 雲端 Supabase | 缺這個檔 build 會直接失敗 |

雲端部署（會影響正式資料，動手前先說明要做什麼）：

```bash
supabase db push --dry-run          # 先看會套用哪些 migration
supabase db push --yes
supabase functions deploy <name> --use-api   # parse-import、ask-trip、extract-products、delete-account、invite（JWT 驗證設定在 supabase/config.toml）
```

- Migration 要向後相容：已安裝的舊版 App 會繼續呼叫舊參數。新增 RPC 參數一律給預設值，並 `drop function` 舊簽名、重新 `grant`（範例見 `20260925000018_place_local_address.sql`）。
- Claude 模型：`ai/*/src` 的 `DEFAULT_MODEL`（目前 `claude-sonnet-5`），可用 Edge Function 環境變數 `ANTHROPIC_MODEL` 覆寫。API key 由擁有者用 `supabase secrets set` 設定。

## 踩過的坑（改相關程式前請先看）

- **SwiftUI 泛型層層巢狀會在 Release 版把主執行緒堆疊用光而閃退**（ForEach → if → Section → ForEach → 泛型列）。清單拆成小的非泛型 View，必要時用 `AnyView`（見 `Features/ShoppingView.swift` 開頭的註解）。Debug 版不一定重現；真機 crash log 用 `xcrun devicectl device copy from --domain-type systemCrashLogs` 取得。
- **View 的 body 不可以回傳自己**：`ErrorText` 曾因批次取代變成 `body { ErrorText(message) }`，任何錯誤訊息一出現就無限遞迴閃退（已有回歸測試）。批次取代後檢查被取代的元件本身。
- `.sheet` 掛在 List 裡的 Section 上不會出現；改用 `NavigationLink` 推頁。
- **Apple 地圖的地址依手機語言回傳**：中文手機拿到「南韓首爾特別市明洞명동10길」。給司機、外開 Naver／Kakao 用 `Place.localAddress`（`address_local`，由 `AppCore/LocalAddress.swift` 以當地語系反查）。
- Apple 地圖查不到韓文（Hangul）地址，羅馬拼音可以（`ScreenshotText.romanizedKoreanAddress`）。
- Vision 文字辨識的自動語言偵測在中文為主的截圖裡會漏掉韓文，所以跑「自動、韓文、日文」三次合併（`ShareCore/ScreenshotText.swift`）。
- 鍵盤：`TextField(axis: .vertical)` 按 return 是換行，要另外給「完成」鈕或 `.scrollDismissesKeyboard(.interactively)`。鍵盤會把貼上的網址自動大寫成 `HTTPS`，判斷網址要不分大小寫。
- `places` 是所有 Trip 共用的列：`upsert_place` 先寫先贏，只在沒有其他 Trip 使用時補空欄位，不能拿來改別人的地點資料。
- 使用者離開加入行程的確認畫面時，要 `reject_proposal` 撤回，不要留下待確認的 proposal。
- 模擬器 build 加 `SWIFT_OPTIMIZATION_LEVEL=-O` 想重現 Release 行為時，相依套件 xctest-dynamic-overlay 會讓編譯器當掉；改用模擬器加真實資料重現，或看真機 crash log。
- 模擬器自動化：截圖可能比畫面慢一拍，選單（Picker menu）不會出現在截圖裡；點擊後等一下再截圖。
