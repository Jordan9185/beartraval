# 給 Claude 的規劃任務

請先閱讀我附上的《iOS AI Travel Companion — MVP 規格草案》，再開啟 [可互動 HTML wireframe](https://ai-travel-companion-mvp-wireframe.jordan8125.chatgpt.site/) 了解畫面順序。Wireframe 的 AI、地圖、店家、邀請與同步是示意資料，請以規格中的產品規則與驗收情境為準。

我要以 **原生 iOS App（SwiftUI + Share Extension）** 規劃 MVP。先做規劃，不要直接寫程式。請交付：

1. 一頁架構總覽：iOS App、Share Extension、後端、AI、地圖／POI、同步的資料流與責任邊界。
2. 按依賴順序拆成可交付的 work packages：每包範圍、先決條件、完成證據、對應 AC。請以能先驗證核心路徑為優先，不要只按頁籤切工。
3. 關鍵資料模型、API／事件契約、權限矩陣、版本衝突與錯誤狀態設計。
4. Route Match 的可實作算法與首爾／廣島實地資料驗證方案；明確區分增加旅行時間、停留時間與固定時間可行性。
5. Share Extension 在 Threads／IG 真機可取得資料的驗證計畫與無法取得完整內容時的退路。
6. 需要我決定的少數產品／技術問題，列出選項、影響與你的建議；已在規格確認的 UX 原則不要重新打開。
7. MVP 交付與驗收計畫：模擬器、真機、兩人兩裝置同步、失敗情境與證據。不要把 wireframe 可點擊當成 iOS 功能完成。

請對每一項標明 **已確認規格／你的建議／需要實測或我決策**。先產出規劃與風險清單，等我確認後再拆開發任務。
