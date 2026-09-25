# 行程文字解析（AI）

Issue #3。把使用者貼上的行程文字轉成**草稿**，交給 Confirm Places 畫面確認。規格見 [spec §5.1](../../docs/spec/ios-ai-travel-companion-mvp-spec.md)、[規劃 §3.2](../../docs/planning/mvp-technical-plan.md)。

## 內容

| 檔案 | 說明 |
|---|---|
| `src/schema.ts` | 輸出格式（Zod）：`days[] → stops[]`，含原文片段、地點名稱、分店線索、時間、疑似固定、待確認原因。**沒有「已提交」狀態** |
| `src/prompt.ts` | System prompt 與使用者訊息（附每個旅行日的星期，讓「週五」能對到日期） |
| `src/parse.ts` | `parseItinerary()`：呼叫 Claude（structured outputs），失敗回 `PARSE_FAILED` 類型的結果；AI Gateway 與評測共用 |
| `src/validate.ts` | 對照原文檢查草稿：日期超出旅程或不存在（如 2/30）、時間格式錯誤、原文片段空白或對不上、沒有（或空白）地點名稱 → 降級為待確認 |
| `eval/cases.ts` | 評測集（24 份；除 1 份濃縮自真實 ChatGPT 行程外，**皆為合成資料**） |
| `eval/score.ts`, `eval/run.ts` | 評分與執行 |

## 使用

```
npm install
npm test            # 單元測試（不呼叫 API）
npm run eval:dry    # 用預期答案自我檢查評分器（不呼叫 API）；有任何不通過即以非 0 結束
npm run eval        # 實際呼叫 Claude API，需要 ANTHROPIC_API_KEY，會產生費用
npm run eval -- --effort high --only seoul-korean,hiroshima-japanese
```

`npm run eval` 會輸出：有效輸出率、找到的 Stop、日期、開始時間、固定判斷、必要旗標（含 AC-01 的 `ambiguous_branch`）、誤判旗標、非 Stop 是否被排除、延遲與 token 數；完整結果存在 `eval/results/`（不進 git）。

## 評測集

- 首爾 15 份、廣島 6 份、首爾＋廣島跨城市長行程 1 份（濃縮自真實 ChatGPT 行程）、無地點 1 份、prompt injection 1 份；來源格式涵蓋 ChatGPT markdown、LINE 對話、備忘錄、英日韓中混合。
- 陷阱：無分店的連鎖店、分店在上下文中才出現、模糊時間、星期標籤、Day N、各種日期寫法、旅程外日期、同一地點不同天、預算/提醒等非 Stop、航班/新幹線/渡輪/訂位。
- 預期答案只列「一定要對」的欄位，不是完整標準答案；比對地點用別名的子字串。

**待補**：真實使用者貼過的行程文字（去識別化後加入，並優先於合成資料）。

## 模型與費用

預設 `claude-opus-5-5`（effort `medium`；`high` 在真實 7 天行程上需 2–5 分鐘，接近 Edge Function 時限）、adaptive thinking，並開啟伺服器端 refusal fallback（`fallbacks: "default"`）。實際跑 `npm run eval` 前先確認費用；可用 `--effort` 比較不同設定的準確率與 token 數。
