# BearTravel — iOS AI Travel Companion

把已排好的旅行匯入，將旅途中看到的地點或想買的商品與**每日既定路線**比較，讓使用者自己決定是否加入行程。

- 平台：原生 iOS（SwiftUI + Share Extension）
- 分頁：旅程／今天／地圖／收藏／購物（Trip / Today / Map / Saved / Shopping）；右上 AI 入口，右下全域新增
- 目前階段：**MVP 功能完成（WP1–WP11），待真機、雲端與實地驗收**（見 [驗收報告](docs/acceptance/mvp-acceptance.md)）

## 三條必須走通的主流程

1. 貼文字行程 → 解析 → 確認地點／固定時間 → 建立 Trip 與 Base Route → Today
2. Threads／IG 分享 → 辨識候選地點 → 確認 → Route Match → 收藏或加入某天
3. 新增商品 → 搜尋可能販售店 → Route Match → 安排購買 → 標記已購買

## 文件

| 文件 | 說明 |
|---|---|
| [docs/spec/ios-ai-travel-companion-mvp-spec.md](docs/spec/ios-ai-travel-companion-mvp-spec.md) | 產品／行為規格草案 v0.1（規則、範圍、驗收情境 AC-01～AC-14） |
| [docs/spec/share-inbox-proposal.md](docs/spec/share-inbox-proposal.md) | 分享後整理／Travel Inbox 產品流程與驗收情境；實作狀態見最新交接 |
| [docs/spec/claude-ios-planning-brief.md](docs/spec/claude-ios-planning-brief.md) | 規劃任務說明 |
| [docs/acceptance/mvp-acceptance.md](docs/acceptance/mvp-acceptance.md) | MVP 驗收報告：AC-01～AC-14 證據與待辦 |
| [docs/planning/mvp-technical-plan.md](docs/planning/mvp-technical-plan.md) | MVP 技術規劃 v0.1（決策 D1–D13；D9 尚未實作）：架構、Work Packages、資料契約、Route Match、Share 驗證、驗收計畫 |
| [docs/planning/share-inbox-delivery-plan.md](docs/planning/share-inbox-delivery-plan.md) | 分享收件、自動整理與行程模板的開發計畫；文字／圖片首批功能已實作，影片驗證仍待完成 |
| [AGENTS.md](AGENTS.md)、[docs/handoff/](docs/handoff/) | 給 coding agent（Codex 等）的工作說明與最新交接：目前狀態、待處理、踩過的坑 |

參考 wireframe：<https://ai-travel-companion-mvp-wireframe.jordan8125.chatgpt.site/>（示意資料，非正式架構）

## 開發

需求：Xcode 26+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。`.xcodeproj` 由 `project.yml` 產生，不進版控。

```bash
xcodegen generate
open BearTravel.xcodeproj
```

- 後端：本機 `supabase start` 後，把 anon key 填進 `Config/Local.xcconfig.local` 的 `SUPABASE_ANON_KEY`（詳見 [supabase/README.md](supabase/README.md)）。
- Release（TestFlight）：需要 `Config/Cloud.xcconfig.local`（雲端網址與 anon key，已 gitignore）；缺少時 `SUPABASE_URL` 會是本機位址，build 直接失敗。
- 首批分享版本只在網址、文字及最多十張圖片的分享清單出現；影片連結只保存實際取得的來源，不宣稱已辨識影片畫面或語音。純影片檔入口待真機驗證後再開啟。
- 真機簽章：建立 `Config/Local.xcconfig.local`（已 gitignore），填 `DEVELOPMENT_TEAM = <Team ID>`；bundle id 衝突時再加 `BUNDLE_ID_PREFIX = com.<你的名字>`。
- 結構：`App/`（App target）、`ShareExtension/`、`UITests/`、`Packages/AppCore`（`AppCore` Domain／規則／後端呼叫、`Features` SwiftUI 頁、`ShareCore` 分享流程）、`supabase/`（migrations、SQL 測試、Edge Functions）、`ai/`（行程解析、AI 助手與評測）、`Tools/RouteSpike`（S1 實測工具）。
- 測試：`swift test --package-path Packages/AppCore`，或在 Xcode 跑 BearTravel scheme 的 Test。
- Spike 工具：DEBUG build 在 Today 右上角 🐞。

## 下一步

技術決策見規劃文件第 6 節（D1–D13；D9 每日以住宿為起訖尚未實作）。Spike S1–S4 與 MVP WP1–WP11 已完成；接下來是真機、雲端與實地驗收（見[驗收報告](docs/acceptance/mvp-acceptance.md)「需要人工完成」），以及 [2026-09-25 review](docs/review/2026-09-25-project-review.md) 的後續修正。
