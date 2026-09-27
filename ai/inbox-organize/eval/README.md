# 真實截圖評測

原圖與模型結果放在專案忽略的 `build/qa/`，不要提交社群圖片、帳號或人像。評測不建立正式收件、不變更旅程。

## 先跑裝置端 OCR

在本機建立清單，格式為 `[{"id":"sample","path":"/absolute/source.png"}]`，然後於專案根目錄執行：

```sh
SCREENSHOT_EVAL_MANIFEST="$PWD/build/qa/manifest.json" \
SCREENSHOT_EVAL_OUTPUT="$PWD/build/qa/ocr" \
swift test --package-path Packages/AppCore --filter ScreenshotEvaluationTests
```

直接呼叫 App 的 `ScreenshotText` 與 `ImageDownscale`，記錄原圖、1024、2048 三種尺寸的實際文字列、建議搜尋名稱、大小與耗時。測試成功僅表示評測完成，沒有將每一列判為正確。

## 再跑實際模型

建立另一份清單，`images` 指向上一步輸出的 JPEG（絕對路徑），可測單圖、多圖或重複圖片：

```json
[{"id":"sample","images":["/absolute/build/qa/ocr/sample-2048.jpg"],"reviewNotes":"逐項核對店名與來源；沒有地址就不可補出分店"}]
```

執行環境已有 `ANTHROPIC_API_KEY` 時，在本目錄執行 `npm run eval -- /absolute/manifest.json /absolute/build/qa/model`。金鑰只用環境設定，不寫入清單、文件或聊天。`ANTHROPIC_MODEL` 可覆寫模型。

每張輸出保留原始結構化結果、程式驗證後結果、實際模型、時間與 token 用量。費用未換算；沒有金鑰或請求失敗就回報失敗，不生成假模型結果。不可把 `npm test` 的合成輸出或 OCR 結果當成雲端模型準確率。

## 本批人工核對標準

| 樣本 | 應保留 | 不可臆測／混淆 |
|---|---|---|
| LOE | LOE 香水、聖水區域線索 | 瓶身不清楚的型號、精確門市、現價與庫存 |
| 美食問答／回覆 | no more pizza、首爾林；韓文店名需核對字形 | 帳號、提問列舉的料理不可當成具名餐廳 |
| Aesop／墨鏡 | 分成品牌購物線索與另一篇墨鏡內容 | 不能互借店家；模糊招牌不能套用提示詞預設名稱 |
| 餅乾巢狀圖 | 奶油餅乾／BUTTER SAND 等可見商品線索 | Trip.com 不是商店，局部品牌不能補全 |
| 無垢屋 | 無垢屋／무구옥、人蔘雞、聖水線索；相同圖片不重複列同一項 | 沒有地址或預訂時間，不能自行確定位置或 Fixed |
| 水芹菜烤肉 | 烤肉、煎餅作低信心搜尋線索 | 爐具品牌不是餐廳，底部裁切文字不能補完整店名 |
| 未具名餐點 | 可見餐點作低信心線索，或無法辨識時留空 | 餐盤殘字、前篇服飾招牌不當作本篇餐廳 |

上述為可見來源的審查標準，不是使用者確認過的精確分店答案。全部樣本均不應因手機時間、發文日期或圖片順序生成正式行程。
