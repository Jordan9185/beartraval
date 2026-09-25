# 專案審查（2026-09-25）

範圍：`claude/github-new-project-v1pk1b` 分支，審查時最新 commit 為 `e5511f8`。共三項審查：程式與設定、畫面流程（UX）、視覺風格。

**方法**：每項審查先由多個審查者分頭閱讀程式碼，再由三個不同角度的驗證者逐條檢查。至少兩位驗證者確認的項目，才列為「已確認」。

**限制**：
- 這個環境沒有 Xcode，所有畫面相關結論都來自閱讀 SwiftUI 程式碼，沒有實際執行 App。
- 驗證階段中途用完額度，有 46 項程式問題、233 項 UX 建議沒有驗證完。其中嚴重度為高的 3 項程式問題已人工確認，列在下方並標「人工確認」。
- 本機測試全部通過：SQL 10 組加上 2 個並發測試、`ai/itinerary-parse` 15 項、`ai/trip-assistant` 9 項。

## 1. 優先修正（高）

| # | 問題 | 位置 | 修法 |
|---|---|---|---|
| H1 | **離線佇列會重複送出、漏送，甚至閃退。** `flush` 是 actor 方法，在 `await` 期間可被重入。App 會從多處同時呼叫 flush（啟動、恢復連線、收藏或購物重新整理）。重疊時，同一筆會送兩次、下一筆沒送就被移除；佇列只有一筆時會對空陣列取 `items[0]` 而閃退。 | `Packages/AppCore/Sources/AppCore/OfflineQueue.swift:61` | 加 `isFlushing` 旗標，或讓所有呼叫共用同一個進行中的 Task。移除前先確認 `items.first?.id == item.id`。 |
| H2 | **沒有已定位 Stop 的日子會被算成「+0 分」並選為最佳日**（人工確認）。n = 0 時兩段路程預設為 `.minutes(0)`，結果是 `.matched(addedTravelMinutes: 0)`。違反「算不出時不可編造分鐘數」。 | `Packages/AppCore/Sources/AppCore/RouteMatch.swift:239` | `match()` 在 `n == 0` 時回傳 `.unavailable`（例如 `.noRoutableStops`）。畫面上顯示「這天還沒有已定位的行程」。 |
| H3 | **建好第一個旅程後，「今天」和「地圖」仍顯示「尚未建立旅程」，按鈕又把人送回「旅程」分頁，形成迴圈**，要重開 App 才會好。`TripStore.start()` 只在啟動時呼叫一次，建立或加入旅程後都不會更新。 | `Features/TripViews.swift:48`、`TripStore.swift:39`、`RootView.swift:32` | 建立或加入後呼叫 `store.start()`，設定 `selectedTripID = 新 trip.id`，再切到「今天」。 |
| H4 | **解析超過 60 秒就被當成「解析失敗」**，按重試還會再解析一次、付兩次 AI 費用。App 用預設 60 秒的請求逾時等 Edge Function，長行程需要 1～2 分鐘。 | `Features/ImportFlowView.swift:122`、`AppCore/Import.swift:242`、`supabase/functions/parse-import/index.ts:70` | 回來的狀態若仍是 `.parsing`，就留在解析中並持續輪詢 `parse_progress`，直到 parsed 或 failed。伺服器端也要擋同一個 import 同時被解析兩次。 |
| H5 | **離線或 MapKit 被限流時，所有地點都被自動標成「Apple 地圖沒收錄」**，畫面還說「全部已自動處理，可以直接建立」。`PlaceSearch` 出錯時回傳 `[]`，和「查無結果」無法區分。 | `AppCore/ConfirmPlaces.swift:112`、`AppCore/PlaceSearch.swift:68` | 搜尋結果區分 found、notFound、unavailable。unavailable 時不要自動決定，改顯示「地圖搜尋暫時無法使用」並提供重新搜尋。 |
| H6 | **離線時開 App，若登入 token 已過期，會進登入頁而不是顯示快取的旅程**（人工確認）。`observe()` 把過期的 session 一律當成未登入，但離線時 SDK 無法更新 token。 | `Features/SessionModel.swift:42` | session 存在但過期時維持「確認登入中」，等 SDK 更新成功或明確失敗後再切換；離線時直接用快取。 |

## 2. 應修正（中）

**後端與 AI**

| 問題 | 位置 |
|---|---|
| 任何登入帳號都能新增或修改共用的 `places` 資料（例如中文名），影響所有 Trip | `supabase/migrations/20260925000010_place_chinese_name.sql:238` |
| `commit_itinerary` 的 `p_expected_route_revision` 傳 NULL 時會跳過 revision 檢查；`p_stops` 傳 NULL 時會刪光當日所有 Stop | `20260924000001_core_itinerary.sql:311`、`:317` |
| Stop 從行程移除後，對應的收藏仍停在 `added_to_itinerary`，也無法再收藏一次 | `20260924000005_saved_places.sql:72` |
| 刪除帳號分兩步且不在同一交易：轉移 Trip、刪除原文等步驟完成後，若 `deleteUser` 失敗無法還原 | `supabase/functions/delete-account/index.ts:24` |
| `ask-trip` 和 `parse-import` 沒有每位使用者的次數或額度限制，任何成員都能無限制地產生 Claude 費用 | `supabase/functions/ask-trip/index.ts:18` |
| `parseItinerary` 的 `max_tokens` 和 `invalid_output` 判斷永遠執行不到：SDK 在 `finalMessage()` 內就先拋錯 | `ai/itinerary-parse/src/parse.ts:83` |
| 登出後，App Group 內的旅程清單與 snapshot 快取仍在；下一個帳號離線開 App 時會看到上一個帳號的資料（人工確認） | `Features/TripStore.swift:33` |

**畫面與流程**

| 問題 | 位置 |
|---|---|
| 沒有旅程時，空狀態只有「建立旅程」；「加入好友的旅程」藏在右上角圖示裡 | `TripViews.swift:41` |
| 錯誤訊息直接顯示系統英文或錯誤碼，例如「讀取失敗：The Internet connection appears to be offline.」「資料不正確（INVALID_DATES）」「(AppCore.BackendError error 4.)」 | `TripViews.swift:62`、`:156`、`SessionModel.swift:98`、`ImportFlowView.swift:170` |
| 透過邀請連結加入後只關掉畫面，沒有帶到剛加入的旅程 | `RootView.swift:32` |
| 貼上的不是邀請連結時，「加入」按鈕只是變灰、不說原因；欄位也沒關自動修正 | `MembersView.swift:128` |
| 確認地點時只能從最多 5 個候選中選，不能換關鍵字重新搜尋（分享流程可以） | `ImportFlowView.swift:366` |
| 自動處理的項目不顯示日期，AI 放錯天也改不了 | `ImportFlowView.swift:237` |
| 「建立旅程」按鈕和「還有 N 項需要確認」都在長表單的最底部 | `ImportFlowView.swift:247` |
| 搜尋還沒跑完時就能按「其餘 N 項先只保留名稱」，結果本來能自動定位的地點也被標成未定位 | `ImportFlowView.swift:196` |

低嚴重度的 18 項程式問題與 10 項 UX 問題，包括 README 說明不符、測試缺口、無障礙標籤等，完整清單見 `docs/review/findings.json`。

## 3. 視覺風格（簡潔、舒服、符合主題）

完整樣式指南見 [style-guide.md](style-guide.md)，共 100 項建議全部經驗證確認。要點：

1. **橘色太多**：16 處、約 8 種意思，包括固定行程的鎖、未安排、庫存未知、無法估算、離線、時區不符、解析失敗、AI 無法判斷。建議橘色只代表「不確定、需要注意」；固定行程的鎖改成灰色，未安排和庫存未知改成次要灰字，但文字保留。
2. **沒有品牌主色**：沒有 AccentColor，所有按鈕都是 iOS 預設藍。
3. **地圖圖釘用了 5 種顏色**：每種圖釘本來就有不同圖示。建議只留兩色：今日路線用主色，其餘用灰色。
4. **移除除錯資訊與不在色盤內的顏色**：
   - 「資料版本 rN」出現在今天、旅程、地圖三個畫面。
   - 離線橫幅和司機卡用黃色底，而黃色不在色盤內。
5. **同一物件長得不一樣**：「今天」自己畫行程列，沒有用 `StopRow`，所以缺少「未定位」標記，路段列也對不齊。
6. **收藏列太擠**：一列最多疊 6 個小按鈕。建議只留標題、狀態、想去和一個主要動作，其餘點進詳情再做。
7. **司機卡字級太多**：用了 4 種寫死的字級，建議縮成兩層。

### 需要你決定：D13 主色

| 選項 | 來源 | 感覺 |
|---|---|---|
| **A. 熊毛棕 `#9A6440`**（深色模式 `#C8925F`） | Logo 的熊與「BeaRTravel」字樣 | 溫暖、安靜，一看就是這個品牌 |
| B. 行李箱藍 `#2E9CCA` | Logo 的行李箱 | 清爽，但和 iOS 預設藍接近，品牌感弱 |

**建議 A**。決定後，只要新增一個 `AccentColor.colorset` 並在 `project.yml` 加一行設定，全 App 的按鈕、連結、分頁列就會一起換色，不需要逐一改畫面。

## 4. 已排除的誤報

以下項目經驗證不成立：
- 撤銷或過期的邀請預覽頁不會洩漏資料。
- 確認 proposal 後重試回傳 `PROPOSAL_CLOSED` 是預期行為。
- parse-import 查詢失敗回 401 已有其他處理。
