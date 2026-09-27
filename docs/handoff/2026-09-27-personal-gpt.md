# 全 App 切換個人 GPT 訂閱

使用者已確認：個人使用、Mac 必須開機連網且保持喚醒；所有 AI 都使用 ChatGPT／Codex 訂閱額度，不保留付費 API fallback。

## 已交付

- `parse-import`、`ask-trip`、`extract-products`、`organize-inbox`、`discover-places` 已部署為雲端持久佇列入口，移除 Claude client 與 API 呼叫。
- migration 33（先前的收件內容去重）與 34（個人 AI 工作佇列）已套用。原有 RPC 簽名未改。新的 `personal-ai` 入口分別驗證 App JWT 或限定帳號的工作憑證，只有 service_role 能領取／完成工作。
- Mac 工作程式以官方 CLI 0.147.0 的 ChatGPT 登入執行；文字 `gpt-5.6-luna` low，圖片 `gpt-5.6-sol` medium，兩者都已由帳號模型清單確認且實際執行。
- LaunchAgent `com.jordan9185.beartravel.personal-ai` 已安裝並啟動。程式與私有設定在 `~/Library/Application Support/BearTravelAI`，不在公開 repo。沒有更動系統睡眠設定、沒有開對外監聽服務、沒有複製 ChatGPT 登入憑證至雲端。
- 子程序只保留基本環境，拒絕 API key 登入，關閉命令／委派／App 工具；原始圖片於呼叫結束清除。成功結果短暫快取，寫回失敗的結果先保存，重新領回同一工作沿用，不重複推論。
- App 支援非同步回應、輪詢與等待訊息；原文、固定安排、使用者確認才寫正式行程等規則保留。Jordan 手機 Release 已安裝、啟動，重載後實際顯示既有東京五日與行程。

## 驗證

- 本機 PostgreSQL 全部測試與四項並發測試通過；新增佇列測試 21 項，包括帳號隔離、去重、過期租約、原文改動、原子完成、收件線索、店家候選快取與問答記錄。
- Swift 套件摘要 170 項，157 通過、13 因未提供本機整合環境略過；Release build 成功。四個共用 AI 模組測試通過，六個 Edge Functions 的 Deno 檢查通過。個人工作程式模擬測試涵蓋認證、API key 隔離、結構格式、圖片來源、私網拒絕及暫存清理。
- 真 GPT：一句話「東京五日」產生五天非空草稿；雲端另建臨時匯入，先確認 queued，啟動 Mac 後領取並回寫 parsed，model 為 `codex/gpt-5.6-luna`，trip_id 仍為 null。該臨時匯入已刪除，沒有代使用者建立正式旅程。
- 完整五日原文：每天一站，第一天東京晴空塔 10:00、已訂票 Fixed 候選保留。旅程問答回覆同一固定事項，商品文字辨識回傳 MOSS GREEN，店家補查回傳具來源的無垢屋聖水店候選。
- 真圖：使用提供的無垢屋與 LOE 截圖，GPT 能分出餐廳與香水。發現純圖片來源被寫成 OCR 文字後遭驗證器剔除，已以圖片編號 schema 限制修正。Luna 在這批圖片有料理誤分類／地區誤收，圖片改用 Sol 後兩項主體分類正確。
- 本機診斷在 gitignore 的 `build/qa/personal-ai`；worker.log 只記工作狀態與 token 計數，不記 prompt／原圖／憑證。

## 仍需觀察

- 圖片輸出有韓文單字誤辨（無垢屋的韓文附註），不能宣稱 OCR 準確率或地點品質已驗收；仍須地圖候選核對。測試不是全部八張圖片完整驗收。
- 首次重裝啟動畫面曾短暫顯示無法載入旅程，重載後正常；未定位該既有載入／畫面時序原因，不宣稱另修好了這個問題。
- 部分行程補日使用原共用流程和回歸測試；本輪沒有在手機逐項重新建立所有完整／部分案例。實際新入口 UI 操作由使用者接續試用。
- 舊版 App 的三個同步結果入口不支援 202 輪詢，需要本輪 Release。個人模式只開放設定的 owner；其他帳號回未設定個人 AI。
- 仍受 Codex 訂閱共享額度限制。Mac 睡眠／關機時不會處理，額度不足時延後重試，不會改用 API。

設定與停止方式見 [個人 GPT 工作程式](../../ai/personal-worker/README.md)。官方介面依據：[非互動執行](https://learn.chatgpt.com/docs/non-interactive-mode)、[圖片輸入](https://learn.chatgpt.com/docs/image-inputs)。
