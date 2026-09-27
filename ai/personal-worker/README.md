# 個人 GPT 工作程式

手機把經權限檢查的需求保存到 Supabase；Mac 只主動領取指定帳號的工作，再透過官方 `codex exec` 使用 ChatGPT 登入。五個 App AI 入口都走這條路，不呼叫 Claude 或 OpenAI 付費 API。

Mac 必須開機、連網且保持喚醒。螢幕可以關閉；手機不必與 Mac 在同一個網路。關機時工作留在雲端，開機後繼續。額度不足時延後十五分鐘再領取；需要重新登入時保留工作。這會消耗與 Codex 共用的訂閱額度，不是無限用量。

## 本機設定

需要 Node.js 22、Codex CLI（本次驗證 0.147.0），先由本人執行 `codex login`。只接受 `codex login status` 顯示 ChatGPT。不能將登入檔、API key 或工作憑證放進公開 repo／CI。

1. 安裝四個既有 AI 套件與本目錄依賴，再執行 `npm run build`。
2. 在 `~/Library/Application Support/BearTravelAI/config.json` 設定 `codex`（CLI 絕對路徑）、`model`（此帳號實際可用模型）、`runtime`（同目錄下的 runtime）、`endpoint`（personal-ai 函式 HTTPS URL）、`token`（獨立的高熵工作憑證）。目錄權限 700、設定檔 600。
3. 雲端 secrets 設定 `PERSONAL_AI_OWNER_ID` 與同一份 `PERSONAL_AI_WORKER_TOKEN`。雲端不接收 ChatGPT 憑證，Mac 不保存資料庫管理金鑰。
4. 執行 `python3 install.py`，安裝登入 Mac 後自動啟動的 LaunchAgent。此腳本不修改睡眠設定，也不建立對外監聽的網路服務。

模型由官方帳號模型清單確認後指定；文字任務使用 `gpt-5.6-luna`、low effort；設定 `visionModel` 為 `gpt-5.6-sol` 後，含圖片任務使用該模型、medium effort，不能把不在帳號清單內的模型寫成已可使用。

## 資料與重試

- 同一內容去重；每帳號最多三十筆待處理工作、每小時最多三十筆新需求。
- 每個工作最多五次模型呼叫、每次四分鐘。AI 模組原有來源核對、Fixed 保留、格式與權限檢查持續適用。
- 先完成一次結果再寫回；寫回斷線將結果保存在本機私有目錄。租約失效後重新領回同一工作時沿用結果，不再推論。
- 執行中每二十五秒延長租約；使用者修改原文使舊 attempt 失效。舊結果不得覆蓋新原文，正式行程仍須本人確認。
- 工作結束清除雲端輸入圖片／原文副本。原始收件及匯入資料仍依既有規則保留。執行用圖片在結束時清除；成功推論快取十分鐘，僅保存在私有 runtime。
- 網頁網址先檢查 HTTPS、禁止私網並固定 DNS 解析 IP。模型提供的摘要不冒充證據，使用實際下載的網頁文字核對名稱。
- 系統原有收件與行程解析模組仍保留歷史 Claude 評測接頭；正式 Edge Functions 已移除 Claude 呼叫。個人工作程式只以 GPT 接頭執行共用驗證邏輯。CI 僅跑模擬測試，不存取個人登入。

停止：`launchctl bootout gui/$(id -u)/com.jordan9185.beartravel.personal-ai`。再次登入 Mac 會依 LaunchAgent 設定啟動；永久停用可先停止後移走該 plist。更換工作憑證時須同步更新雲端與本機設定並重啟工作程式。
