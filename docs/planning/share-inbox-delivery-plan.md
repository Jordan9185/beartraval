# Travel Inbox 與行程模板：下一階段開發計畫

版本：提案 v0.1 · 2026-09-26  
依據：[分享後整理產品提案](../spec/share-inbox-proposal.md)、[現行 MVP 規格](../spec/ios-ai-travel-companion-mvp-spec.md)、[2026-09-26 交接](../handoff/2026-09-26-codex-handoff.md)。  
狀態：原始排程提案；實際完成與驗證狀態以[實作交接](../handoff/2026-09-26-travel-inbox-implementation.md)為準。現有 MVP 的 D1–D13 與 AC-01～AC-14 保持原基準。

2026-09-26 實作追蹤：文字／圖片收件、個人候選、可編輯模板與確認套用的首批程式已建立；各工作包的實際驗證與剩餘範圍見[實作交接](../handoff/2026-09-26-travel-inbox-implementation.md)。本計畫中的影片畫面／語音管線及真機驗收仍未完成。

## 1. 產品邊界與現況

【本次討論方向】使用者做「分享 → BeaRTravel」後就回原 App。系統自行收下、辨識、查證並整理成**個人**想去／想吃／想買或可編輯行程模板。Inbox 主要顯示處理紀錄與例外，不要求每篇逐項核對。套用正式行程、選歧義分店與公開到共同清單仍由使用者執行。

【已確認規格】正式行程只在人確認後改變；Fixed Stop 不可被自動移動；未確定的地點不參與路線計算；「順路」是增加的旅行時間，無路線資料時為 unknown；Saved 與 Shopping 分開；商品庫存未知時不能宣稱有貨。

【現有程式】`ShareFlowView` 處理單一地點，`ProductImportView` 處理商品，`ShareContent` 只保留第一張圖片縮圖，`PayloadInspector` 對影音檔只記錄型別、檔名與大小，`ShareDraftStore` 是本機 App Group 草稿。`parseItinerary()` 預設 Sonnet 5，但輸入需要已知 Trip 日期與時區；還沒有無日期模板。Saved／Shopping 資料都隸屬 Trip，沒有個人清單。

【交接風險】iOS CI 自 `8d210c8` 後在 macOS `swift test` 卡住，真機 Threads／IG payload 矩陣與新截圖 OCR 效能也尚未驗證。新工作可先做規格、樣本和獨立原型；合入主要分支前須恢復 CI 並取得相應裝置證據。CI 綠燈不等同產品真機驗收。

## 2. 目標流程與元件責任

```text
來源 App → Share Extension → App Group 原始收件 → 上傳／同步 → 個人 Capture
                                                       ↓
                                             持久化辨識工作
                                        文字／圖片／可得影片線索
                                                       ↓
                                        Sonnet 5 結構化候選與來源錨點
                                                       ↓
                                      POI／商品證據查證 + 去重規則
                                                       ↓
                           個人收藏／購物       行程模板       例外 Inbox
                                   \               |               /
                                    使用者選擇時才套用共同清單或正式 Trip
```

| 元件 | 本階段責任 | 約束 |
|---|---|---|
| Share Extension | 接收 payload，原子保存 URL／文字／可得媒體，顯示「已保存在此裝置」或「已同步，正在整理」 | 不做 Sonnet、OCR 多輪、影片抽影格、POI 或 Route Match；儲存失敗不得報成功。 |
| 主 App 同步器 | 依登入身分上傳本機 Capture／附件，斷線重送，顯示進度與帳號歸屬 | 未登入內容登入後一次確認歸屬；切帳號不可靜默上傳。 |
| Supabase 個人資料區 | Capture、附件、辨識工作、個人清單與模板的持久化和 owner-only RLS | 舊版 Trip RPC 保持相容；個人原文不自動公開給旅伴。 |
| AI 管線 | 判斷推薦清單／商品／行程／混合內容，輸出多項候選與模板草稿 | 引用原文片段或影片時間碼；模型推測與查得事實分欄。 |
| 查證與路線 | Apple POI 候選、產品來源、去重、Trip 建議與可行 Route Match | 分店有歧義不選定；不可編造地址、營業時間、售價、庫存或 detour。 |
| 使用者介面 | 已自動歸檔結果、可撤銷、少數需確認項、可編輯模板與套用預覽 | 既有五分頁先維持；Inbox 入口位置經可用性測試再定。 |

【建議】現有 `PayloadInspector` 是診斷工具，其文字預覽會截斷，且檔案表示的暫存 URL 在 callback 後失效。正式收件需另寫 production loader，在檔案 callback 內將可得附件複製到 App Group，保存順序、型別、大小與校驗值；不可把 Inspector 紀錄當原始內容。大型影片保存上限、清理策略與背景上傳需在真機測試後定案。

## 3. 資料與 API 契約草案

### 3.1 新資料【建議】

| 表／儲存 | 最小欄位與關係 | 權限／一致性 |
|---|---|---|
| `inbox_captures` | id、`owner_id`、`client_capture_id`、source app、URL／canonical URL、可得文字、狀態、`input_revision`、created/updated、last_shared_at | Owner-only RLS；`(owner_id, client_capture_id)` 唯一。相同 canonical URL 返回既有 Capture 並更新最後分享時間，不覆寫使用者更正。 |
| `inbox_assets` + private bucket | capture_id、順序、MIME、checksum、bytes、storage path、可得狀態 | 路徑由 owner/capture 限定；下載與刪除要驗 owner。媒體不放進 JSON／公開 bucket。 |
| `inbox_jobs` | capture_id、attempt_id、input_revision、stage、status、model、usage、error code、開始／完成時間 | 同一 revision 只執行一個工作；過期 attempt 不覆蓋新輸入或使用者更正。 |
| `inbox_items` | capture_id、順序、kind、intent、原文片段／時間碼、候選名稱、confidence、missing fields、處置狀態 | 來源片段可回查；每項可單獨失敗、略過、重試。 |
| `personal_entities`、`inbox_item_links` | owner、place 或商品資料、個人類別、resolution status；item 與個人實體多對多 | 同一店／商品可連多個來源；自動歸檔可撤銷；不直接寫 Trip 共同 Saved／Shopping。 |
| `itinerary_templates`／`template_days`／`template_stops` | owner、source capture、草稿 revision、day index、stop order、時段／停留線索、地點或 raw label、來源錨點、明示／推測 | 模板與正式 Trip 分離；外部作者日期或訂位不得自動標成我的 Fixed Stop。 |

【建議】個人清單是新資料域，現有 `saved_places`／`shopping_items` 是共同 Trip 清單。可在既有「收藏」「購物」畫面分段呈現兩種來源，但 UI 必須明確區分「只有我看得到」與「旅伴共用」。從個人項目發布到 Trip 時才呼叫可審核的轉入 RPC，並保留來源關係。

### 3.2 操作契約【建議】

| 操作 | 主要輸入 | 回傳／關鍵規則 |
|---|---|---|
| `create_capture` | client_capture_id、來源 URL／文字／附件清單 | Capture id、created／duplicate、同步狀態；owner 由 JWT 決定，不能由客戶端指定。 |
| `attach_capture_asset` | capture id、順序、checksum、MIME、大小 | 私有上傳位置或結果；上傳完整後才讓工作讀取。 |
| `enqueue_capture_analysis` | capture id、input_revision | job id／既有 job；只入列，不在 Share Extension 等完整辨識。 |
| `get_capture`／`list_captures` | capture id／狀態游標 | 含項目、模板摘要與例外數；不同 owner 不可讀。 |
| `correct_item`／`undo_auto_archive` | item id、預期 item revision、修改內容 | 更正保留 actor／時間；AI 重跑不能覆寫；錯誤 revision 回 stale。 |
| `publish_personal_item` | entity id、trip id、目的清單 | 檢查 Owner／Editor；Viewer 仍可保有個人項目，但不得寫共同資料。 |
| `preview_template_apply` | template id、目標 Trip（或新 Trip 參數）、expected revision | 新增 Stop、待定位、Fixed 衝突、路線可估／unknown；只預覽。 |
| `confirm_template_apply` | preview id、使用者確認的 Stop／順序、expected revision | 原子提交或 `STALE_REVISION`；不部分覆蓋原 Trip。 |

錯誤至少區分 `UNAUTHENTICATED`、`FORBIDDEN_ROLE`、`CAPTURE_UNAVAILABLE`、`ASSET_UNAVAILABLE`、`INPUT_STALE`、`PLACE_UNRESOLVED`、`ROUTE_UNAVAILABLE`、`STALE_REVISION`。外部平台只給不可讀連結時是「已保存但資訊不足」，不是假辨識成功或無限重試。

【需實測或決策】工作執行器選型。現有 `parse-import` 是有 attempt 保護的長請求，適合文字匯入；影片、多附件與使用者關閉 App 後繼續處理需要持久化佇列／worker。先用文字與圖片完成契約，再以真機 payload 和作業時間決定影片 worker 與暫存方案。

## 4. AI 與影片處理門檻

【建議】Sonnet 5 負責「來源內容 → 結構化候選／模板」。新 schema 至少輸出 `content_kind`、`items[]`、可選 `template_days[]`，每個欄位附 `source_span` 或 `video_timecode`、`origin_type`（來源明示／模型推測）、confidence 與 missing fields。後處理先驗 JSON schema 與來源錨點，再查 POI；模型文字不可當地址、庫存或路線分鐘數。

【現況觀察】現有 24 份文字行程評測大多是合成資料；`parseItinerary()` 需要 Trip 起訖日期，因此須另建不依賴日期的模板輸出契約。商品辨識目前只帶一張 JPEG。可重用解析與驗證方式，不能直接把現有 API 當新功能完成。

【建議】影像／影片先在裝置或專責處理層抽代表影格、OCR 與語音轉錄，再把有時間碼的線索交 Sonnet 5。先驗證 Threads／IG Reels、TikTok、小紅書、相簿影片實際提供 URL、文字、縮圖或可用影片檔的比例；只有 URL 且無公開可讀內容時，只保存 URL。不要用影片剪輯先後推斷旅行先後，除非字幕／旁白明示。

**模型與自動歸檔驗收【建議】**：以去識別化真實分享建立固定樣本集，分文字行程、一般推薦貼文、商品、截圖／輪播、可讀影片、只有 URL 六類；對每類記錄來源取得率、地點／商品 precision 與 recall、錯誤分店、分天／順序錯誤、虛構欄位、人工更正率、延遲與單次成本。自動加入個人清單只放行達到預定品質門檻的類別；未達標者仍可保存來源與候選，避免大量錯誤收藏。門檻數值在首輪樣本後定案。【需實測或決策】

## 5. 工作順序與依賴

| 工作包 | 範圍 | 先決條件 | 可檢查成果 | 對應情境 |
|---|---|---|---|---|
| **G0 品質門檻** | 修復交接 P1 的 macOS OCR 測試卡住；記錄真機 payload、兩帳號與媒體保存樣本 | 現有程式 | iOS CI 完成套件與模擬器步驟；Threads／IG 及相簿來源矩陣有日期、裝置、型別。 | SI-01、11、12 |
| **SI-1 快速收件** | Production loader、App Group 原子保存、附件清單與帳號隔離、Share Extension 一步完成 | G0 的基本 payload 樣本 | 離線／未登入／切帳號／重複分享不遺失、不錯帳；UI 如實顯示本機或雲端狀態。 | SI-01、04、06、11、13、17 |
| **SI-2 個人持久化** | Capture、附件、job、owner-only RLS、同步與冪等 API | SI-1 契約 | 兩帳號 DB 測試互不可見；重送同一 capture 不重複；刪除帳號會清理原文／附件。 | SI-04、06、09、10 |
| **SI-3 自動整理** | 文字／圖片分類、Sonnet 5 多項抽取、POI 候選、個人清單歸檔、來源與撤銷 | SI-2、真實樣本集 | 一篇多店／多商品不需逐項按收藏；歧義分店停在例外；每項可追來源。 | SI-02～05、07、13 |
| **SI-4 Inbox 與個人清單 UI** | 結果摘要、真正待處理數、個人／共同清單分辨、單項更正與撤銷 | SI-3 | 分享後不用回 App 也保存成功；已整理內容可在個人清單找到；錯誤結果可撤銷。 | SI-07、09、13 |
| **SI-5 行程模板** | 無日期模板 schema、文字行程自動分類、Day／Stop 編輯、原文錨點 | SI-2、SI-3 的模型驗證 | Day 1–3 可自動成草稿；無天數先未分天；他人的訂位不變我的 Fixed。 | SI-14、15、17 |
| **SI-6 套用與路線** | 新 Trip 建立／既有 Trip 預覽、整批 proposal、Fixed 衝突與 revision、Route Match | SI-5、現有 proposal／route 能力 | 改正式行程前有人確認；STALE 不覆蓋；unknown 不顯示虛構分鐘。 | SI-05、08、16 |
| **SIV 影片驗證與擴充** | 真機影片 payload、影格／字幕／語音管線、時間碼模板、品質與成本測試 | G0、SI-2；可與 SI-3～SI-6 的文字工作並行驗證 | 通過樣本門檻後再開自動影片整理；不可讀連結只顯示已保存與可選補充。 | SI-12、15、17 |

【建議】SI-1～SI-6 每個工作包有獨立變更與驗收記錄，避免把 Capture、個人清單、模板和既有正式行程同時大改。新 DB migration 往後相容，新增 RPC 參數給預設值；舊 App 保持可用。新功能可用配置開關逐階段開啟，先保留現有分享流程作退路。

## 6. 驗收證據與尚待決策

| 層級 | 必要證據 |
|---|---|
| 規則／AI | 固定樣本集與負例：兩分店、只提及不想去、Day 2 與剪輯順序不同、只有 URL、模型編造庫存；輸出 schema 與來源錨點測試。 |
| DB／API | Owner-only RLS、Viewer 不可寫共同 Trip、重送冪等、重跑不覆寫人更正、帳號刪除與附件清理、整批套用 stale revision 測試。 |
| 模擬器 | 一步分享後離開、Inbox 與個人清單結果一致、模板拖動編輯／撤銷、離線與失敗恢復。 |
| 真機 | Threads／IG／相簿實際 payload、Extension 記憶體與完成時間、背景後資料恢復、影片影格／字幕品質；至少兩帳號隱私及共同清單同步。 |
| 實地／路線 | 首爾與廣島分店及交通時間案例；無路線時 unknown，Fixed 衝突與使用者確認錄影。 |

【需實測或決策】個人資料原檔保留多久、影片是否允許雲端處理及一次性的隱私設定、哪些類別可以自動歸檔、Inbox 入口位置、完成後是否推播、影片內容分析的品質門檻。這些決策不阻礙 SI-1 的本機快速收件與文字樣本準備；會影響雲端媒體、個人清單與影片功能的正式開啟。
