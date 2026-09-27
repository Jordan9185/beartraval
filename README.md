# BearTravel — iOS AI Travel Companion

**把旅行資料丟進來，AI 幫你看懂、整理、提出安排；你只需要確認重要選擇，就能帶著行程出發。**

核心為懶人收集、AI 辨識整理與可直接使用的旅程。沒有旅程也能先收內容；正式安排由使用者確認，排入後仍能修改與撤回。這是已採用的產品方向，完整功能仍依開發與驗收證據交付。

- 平台：原生 iOS（SwiftUI + Share Extension）
- 分頁：旅程／今天／地圖／收藏／購物（Trip / Today / Map / Saved / Shopping）
- 目前階段：**核心模組已有實作，完整主線仍有缺口；依 2026-09-27 主軸重新交付，尚未整體驗收**（見[邏輯稽核](docs/review/2026-09-27-app-logic-audit.md)與[最新交接](docs/handoff/2026-09-27-screenshot-recognition.md)）

## 主流程

1. 分享、文字、連結或照片 → 先保存 → AI 辨識多個地點／商品／行程 → 自動整理個人清單或草稿。
2. 明確結果直接可用，歧義集中確認 → 建議旅程與日期 → 使用者核對後排入，保留來源與當地地址。
3. 正式旅程可修改、撤回與重新安排 → 今天／地圖對應同一天 → 導航、司機卡、完成／撤銷購買。

既有行程、收藏集合或一句旅行想法都能作為起點。每個功能都要交代「存在哪、目前狀態、下一步、如何更正、失敗怎麼恢復」。

## 文件

| 文件 | 說明 |
|---|---|
| [docs/spec/ai-first-product-direction.md](docs/spec/ai-first-product-direction.md) | 已確認產品主軸、確認邊界與 AIJ-01～12 驗收基準 |
| [docs/planning/ai-first-delivery-plan-v3.md](docs/planning/ai-first-delivery-plan-v3.md) | 現行工程優先順序、工作包 AJ-0～AJ-4 與交付依賴 |
| [docs/spec/ios-ai-travel-companion-mvp-spec.md](docs/spec/ios-ai-travel-companion-mvp-spec.md) | 產品／行為規格 v0.2（已對齊新主軸，保留 AC-01～AC-14） |
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

依[主線交付計畫 v3](docs/planning/ai-first-delivery-plan-v3.md)從 AJ-0 的真實樣本基線與路線可信度修正開始，再完成 AJ-1「無 Trip 也能收件、AI 整理後找得到結果」。技術決策 D1–D13 沿用，D9 住宿起訖仍未實作；過去 WP 完成記錄不代表本版使用主線或真機驗收完成。
