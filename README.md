# BearTravel — iOS AI Travel Companion

把已排好的旅行匯入，將旅途中看到的地點或想買的商品與**每日既定路線**比較，讓使用者自己決定是否加入行程。

- 平台：原生 iOS（SwiftUI + Share Extension）
- 分頁：Today / Trip / Map / Saved / Shopping；右上 AI 入口，右下全域新增
- 目前階段：**規劃中**（尚未開始寫 App 程式碼）

## 三條必須走通的主流程

1. 貼文字行程 → 解析 → 確認地點／固定時間 → 建立 Trip 與 Base Route → Today
2. Threads／IG 分享 → 辨識候選地點 → 確認 → Route Match → 收藏或加入某天
3. 新增商品 → 搜尋可能販售店 → Route Match → 安排購買 → 標記已購買

## 文件

| 文件 | 說明 |
|---|---|
| [docs/spec/ios-ai-travel-companion-mvp-spec.md](docs/spec/ios-ai-travel-companion-mvp-spec.md) | 產品／行為規格草案 v0.1（規則、範圍、驗收情境 AC-01～AC-14） |
| [docs/spec/claude-ios-planning-brief.md](docs/spec/claude-ios-planning-brief.md) | 規劃任務說明 |
| [docs/planning/mvp-technical-plan.md](docs/planning/mvp-technical-plan.md) | MVP 技術規劃 v0.1：架構、Work Packages、資料契約、Route Match、Share 驗證、待決策、驗收計畫 |

參考 wireframe：<https://ai-travel-companion-mvp-wireframe.jordan8125.chatgpt.site/>（示意資料，非正式架構）

## 下一步

1. 審閱 `docs/planning/mvp-technical-plan.md` 第 6 節的待決策項目。
2. 確認後再把 Work Packages 拆成開發任務（GitHub Issues）。
