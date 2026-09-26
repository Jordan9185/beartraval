# Supabase 後端

決策 D1：Supabase（Postgres + RLS + Realtime + Edge Functions）。設計見 [技術規劃 §3](../docs/planning/mvp-technical-plan.md)。

## 結構

| 路徑 | 內容 |
|---|---|
| `migrations/` | 資料庫 migration（依檔名順序套用） |
| `tests/` | SQL 測試與執行腳本 |
| `tests/support/supabase_shim.sql` | 在一般 Postgres 模擬 Supabase 的 `auth.uid()` 與角色，**只給測試用** |

## 權限模型

- 所有資料表在 `app` schema。用戶端只能 `select`；Trip 資料依有效成員、Travel Inbox 依來源擁有者限制讀取。
- 所有寫入都經由 RPC（`security definer`），在函式內檢查角色；直接 insert/update/delete 一律被拒。
- 行程寫入帶 `expected_route_revision`，不符回 `STALE_REVISION`，不寫入任何資料。
- 當日 `route_revision` 一改變（任何 RPC），觸發器就把該日未確認的 proposal 標為 `stale`。
- Purchase Stop：proposal 的 change 帶 `shopping_item_id`，確認後 Stop 為 `purchase` 並回連商品；Stop 被刪除時商品回到未安排。
- 地點一進入正式行程（stops），同 Trip 同地點的 Saved 自動標為 `added_to_itinerary`，不再出現在待加入清單。

## RPC

依 `migrations/` 目前的定義整理（2026-09-26，含 `20260926000020_apply_inbox_template.sql`）。參數加 `?` 表示有預設值可省略。

**行程與地點**

| 函式 | 權限 | 說明 |
|---|---|---|
| `create_trip(name, start_date, end_date, time_zone)` | 已登入 | 建 Trip、每日 TripDay、Owner 成員（最多 60 天） |
| `commit_itinerary(day_id, expected_route_revision, stops jsonb)` | Owner／Editor | 以有序清單取代當日行程；revision 與 stops 皆必填；回傳新 route_revision |
| `update_day(day_id, time_zone?, transport_mode?)` | Owner／Editor | 每日時區與交通方式；有變更時 route_revision +1（該日未確認的 proposal 變 stale） |
| `get_trip_changes(trip_id, since_revision)` | 成員 | 重連後補拉錯過的變更 |
| `upsert_place(provider, provider_place_id, name, latitude, longitude, name_local?, address?, country_code?, name_zh?, address_local?)` | 已登入 | 註冊已確認的 POI（provider 限 `apple_mapkit`／`apple_maps_server`）。同一 id 已存在時回傳既有資料；只在沒有其他 Trip 使用時補上缺少的當地名／中文名／當地文字地址（`address_local`，給計程車卡片與 Naver／Kakao 用；Apple 回傳的 `address` 會隨手機語言變成中文）；座標與既有資料相差超過 1 km 時另建一筆 |
| `delete_trip(trip_id)` | Owner | 刪除 Trip（含匯入原文、AI 紀錄） |

**文字匯入（AI 草稿）**

| 函式 | 權限 | 說明 |
|---|---|---|
| `create_import(trip_name, start_date, end_date, time_zone, raw_text)` | 已登入 | 建 ImportSession，保留原文 |
| `update_import_text(import_id, raw_text)` | 建立者 | 回到原文編輯；清除舊草稿，並結束進行中的解析（其結果之後會被丟棄） |
| `commit_import(import_id, days jsonb)` | 建立者 | 在同一交易建 Trip、各日 Stop；Place 須先 `upsert_place` |
| `begin_parse(import_id)` | 僅 service_role | 取得解析權，回傳這次解析的 attempt id；已有解析進行中（8 分鐘內）回 null |
| `record_parse_progress(import_id, attempt, progress jsonb)` | 僅 service_role | 解析進度（等待畫面用）；只接受目前的 attempt |
| `record_parse_result(import_id, attempt, status, result, error, model)` | 僅 service_role | 寫入解析結果；attempt 已被取代（原文已改、解析被重新認領）或已建立 Trip 時不寫入並回傳 false |
| `consume_ai_quota(kind)` | 已登入 | AI 呼叫次數限制（`parse`／`ask`／`extract`／`inbox` 每小時、每天上限）；超過回 false |

**分享收件匣（個人資料）**

| 函式 | 權限 | 說明 |
|---|---|---|
| `save_inbox_capture(client_capture_id, fingerprint, canonical_url, source_url, title, raw_text, unavailable_count?)` | 已登入 | 保存實際取得的來源；同帳號、同連結或同內容重送不覆寫原文與更正 |
| `register_inbox_asset(capture_id, ordinal, kind, mime_type, byte_count, sha256, storage_path?)` | 來源擁有者 | 登記附件；目前只有圖片縮圖上傳私有 bucket，影片原檔留在裝置 |
| `update_inbox_item(item_id, expected_revision, display_name?, archived?)` | 來源擁有者 | 更正候選名稱或撤銷個人清單項目；版本過期拒絕 |
| `confirm_inbox_place(item_id, expected_revision, place_id)` | 來源擁有者 | 確認 MapKit 地點；未確認項目不參與路線 |
| `update_inbox_template(template_id, expected_revision, title, draft)` | 來源擁有者 | 編輯無日期行程模板；版本過期拒絕 |
| `apply_inbox_template(template_id, expected_template_revision, client_op_id, trip_id?, start_date?, time_zone?, expected_day_revisions?)` | 來源擁有者，既有 Trip 須 Owner／Editor | 使用者確認後原子建立或追加旅程；保留既有 Fixed Stop，新增項目為待定位文字，檢查模板與每日版本，重送冪等 |
| `begin_inbox_analysis(capture_id)`／`finish_inbox_analysis(capture_id, attempt, result, error?, model?)` | 僅 service_role | 背景分析認領與落庫；過期 attempt 不能覆寫更正 |

**變更提案（Route Match → 正式行程）**

| 函式 | 權限 | 說明 |
|---|---|---|
| `create_proposal(day_id, expected_route_revision, change jsonb, route_match jsonb?, created_by_ai?)` | Owner／Editor | 建立加入行程的 proposal，不寫入 Stop。地點須已確認；`before_stop_id`／`after_stop_id` 須是當日現存 Stop，`kind` 只能是 `standard`／`purchase`，`dwell_minutes` 為 0–1440 的整數 |
| `confirm_proposal(proposal_id)` | Owner／Editor | 插入 Stop；當日已變更時回 `{"status":"stale"}` 且不寫入；帶 `shopping_item_id` 時建立 Purchase Stop，商品已有安排中的 Purchase Stop 則回 `ALREADY_SCHEDULED` |
| `reject_proposal(proposal_id)` | Owner／Editor | 取消未確認或 stale 的 proposal；已確認的不受影響 |

**收藏（Saved）**

| 函式 | 權限 | 說明 |
|---|---|---|
| `save_place(trip_id, raw_label, category?, place_id?, source jsonb?, client_op_id?)` | Owner／Editor | 收藏到共同 Saved（不改行程）。同一 `canonical_url` 或同一地點回傳既有項目（`duplicate: true`）並記錄想去；同網址先前存成未定位、這次有地點時，改為補上該項目的地點；兩人同時收藏同一地點也回傳先存的那筆 |
| `set_saved_interest(saved_id, interested)` | Owner／Editor | 想去（成員集合） |
| `resolve_saved(saved_id, place_id)` | Owner／Editor | 補填未定位項目的地點（已有地點回 `ALREADY_RESOLVED`）；該地點已在行程中時標為 `added_to_itinerary` |
| `dismiss_saved(saved_id)` | Owner／Editor | 移除（30 天後清除） |

**購物**

| 函式 | 權限 | 說明 |
|---|---|---|
| `add_shopping_item(trip_id, name, note?, url?, client_op_id?)` | Owner／Editor | 新增商品（未安排）；重送冪等 |
| `set_shopping_interest(item_id, interested)` | Owner／Editor | 想買（成員集合，與購買分開） |
| `set_shopping_image(item_id, image_path)` | Owner／Editor | 商品圖片（private bucket `shopping-images` 中該 Trip 的資料夾）；傳 null 移除 |
| `add_merchant_candidate(item_id, place_id, evidence_type, evidence_url?, evidence_note?)` | Owner／Editor | 可能販售店與證據（30 天過期，再加一次會更新證據並重新計算）；庫存一律 unknown |
| `record_purchase(item_id, purchased, client_op_id?)` | Owner／Editor | 購買／撤銷事件；撤銷限購買者或 Owner（購買者帳號已刪除時只有 Owner 可撤銷） |

**成員與帳號**

| 函式 | 權限 | 說明 |
|---|---|---|
| `create_invite(trip_id, role, expires_in?, max_uses?)` | Owner | 回傳一次性明文 token，DB 只存 SHA-256；預設 7 天 |
| `revoke_invite(invite_id)` | Owner | |
| `accept_invite(token)` | 已登入 | 加入 Trip；已移除的成員重新加入時採邀請的權限 |
| `set_member_role(trip_id, user_id, role)` / `remove_member(trip_id, user_id)` | Owner | 不能設為 Owner、不能改自己 |
| `set_display_name(name)` | 已登入 | 顯示名稱 1–60 字（只有共同 Trip 的成員看得到） |
| `invite_preview(token)` | 僅 service_role | 邀請預覽頁用：Trip 名稱、日期、邀請者、權限；不含行程 |
| `prepare_account_deletion(user_id)` | 僅 service_role | 刪除帳號前：擁有的 Trip 轉給資歷最久的 Editor（其次 Viewer）或刪除，本人立即退出所有 Trip，事件作者清為 null；可重複執行 |
| `purge_tombstones()` | 僅 service_role | 清除 30 天前的軟刪除 Stop 與移除的 Saved（pg_cron 每日 03:17） |

內部函式（`require_role`、`trip_role_of`、`bump_trip`、`distance_km`、`uuid_or_null`、`place_used_by_others` 與觸發器）不是 API。

Realtime：訂閱 `app.trip_events` 的 postgres_changes（依 `trip_id` 過濾，UUID 用小寫字串），收到後依 revision 重新拉取；重新訂閱成功時以 `get_trip_changes` 補拉。

邀請預覽頁：`GET /functions/v1/invite?token=…`（Edge Function `invite`，公開）。「在 App 開啟」目前用 `beartravel://invite?token=…`；有網域後改成 Universal Link。

離線佇列：`save_place`、`add_shopping_item`、`record_purchase` 接受 `client_op_id`，重送時回傳第一次的結果，不會重複新增。

## 錯誤代碼

SQLSTATE `PTnnn` 會讓 PostgREST 回傳 HTTP `nnn`：

| SQLSTATE | 訊息 | HTTP |
|---|---|---|
| PT401 | `UNAUTHENTICATED` | 401 |
| PT403 | `FORBIDDEN_ROLE` | 403 |
| PT404 | `NOT_FOUND`、`INVITE_INVALID` | 404 |
| PT409 | `STALE_REVISION`、`ALREADY_COMMITTED`、`PROPOSAL_CLOSED`、`ALREADY_SCHEDULED`、`DUPLICATE_SAVED`、`ALREADY_RESOLVED` | 409 |
| PT410 | `INVITE_EXPIRED`、`INVITE_REVOKED` | 410 |
| PT422 | `INVALID_STOPS`、`STOP_NOT_IN_DAY`、`PLACE_UNRESOLVED`、`PLACE_NOT_FOUND`、`INVALID_PLACE`、`INVALID_DATES`、`INVALID_TIME_ZONE`、`DATE_OUTSIDE_TRIP`、`EMPTY_TEXT`、`INVALID_SAVED`、`INVALID_ITEM`、`EVIDENCE_REQUIRED`、`INVALID_IMAGE`、`INVALID_ROLE`、`INVALID_NAME`、`INVALID_KIND`、`INVALID_CAPTURE`、`INVALID_ASSET_PATH`、`INVALID_TEMPLATE`、`INVALID_REQUEST`、`DAY_UNASSIGNED`、`TRIP_DATE_REQUIRED`、`TRIP_TOO_SHORT` | 422 |

## 測試

需要 Postgres 16+ 的 `initdb`、`pg_ctl`、`psql`（不需要 Docker；CI 與 `config.toml` 一樣用 17）：

```
supabase/tests/run.sh
```

會建立暫時的資料庫，套用 shim 與 migration，每個 `*.test.sql` 在獨立資料庫執行，最後跑三組兩個連線同時寫入的並發測試（第一個連線持有鎖，直到確認第二個連線正在等鎖，不靠固定等待時間）。CI：`.github/workflows/db-tests.yml`。

## 本機開發（iOS App 連線用）

需要 Docker（OrbStack 或 Docker Desktop）與 Supabase CLI（`brew install supabase/tap/supabase`）。

```bash
supabase start      # 套用 migrations，啟動 API（:54321）與 Mailpit（:54324）
supabase status     # 取得 anon key
```

- `config.toml` 已把 `app` 加入 exposed schemas。
- 把 `supabase status` 的 anon key 填進 `Config/Local.xcconfig.local` 的 `SUPABASE_ANON_KEY`，模擬器即可連 `http://127.0.0.1:54321`。
- 登入：Email＋密碼（決策 D7）。Email 確認關閉（註冊後直接登入），密碼至少 8 字元（`minimum_password_length`）。

## Edge Function：`parse-import`（AI Gateway）

`functions/parse-import` 以使用者 JWT 讀取 ImportSession（RLS），用 `ai/itinerary-parse` 的 `parseItinerary()` 呼叫 Claude，把草稿寫回 `parse_result`（service role）。草稿不是正式行程，使用者在 App 逐一確認後才由 `commit_import` 寫入。

- API key：本機放 `supabase/functions/.env`（`ANTHROPIC_API_KEY=...`，已 gitignore），雲端用 `supabase secrets set ANTHROPIC_API_KEY=...`。
- 沒有 key 時回 `missing_api_key`，session 標為 failed，原文保留。
- 同一份匯入同時只跑一個解析（`begin_parse` 的 attempt id）；解析中使用者改了原文，舊解析的結果會被丟棄。
- 日誌：每次一行 JSON（`ms`、`input_tokens`、`output_tokens`、`status`），不記原文與 prompt（D11）。

## Edge Function：`ask-trip`（AI 助手）

以使用者 JWT 讀取 Trip（RLS），組成 Trip 範圍的上下文，用 `ai/trip-assistant` 的 `askTrip()` 回答並驗證引用。路線分鐘數只能來自 App 在裝置上算好的 `route_facts`。回傳的 `proposal` 只是建議：App 重新計算後建立 `created_by_ai = true` 的 proposal，仍需使用者確認。問答存在 `app.ai_messages`（刪 Trip 即刪，D11）；日誌只記延遲、token 數與狀態，不記 prompt。

## Edge Function：`delete-account`

刪除呼叫者的帳號（App Review 要求）：先 `prepare_account_deletion`（擁有的 Trip 轉給其他成員或刪除、協作紀錄的作者清為 null），清理個人收件匣私有圖片，再 `auth.admin.deleteUser`。

## Edge Function：`organize-inbox`

以使用者 JWT 及 owner-only RLS 確認來源，背景讀取實際分享的文字與最多十張私有圖片縮圖，用 `ai/inbox-organize` 整理個人候選與行程模板。純連結、無可讀內容的影片不猜測畫面。分析結果只寫個人收件匣；套用正式旅程需使用者在 App 明確確認。缺少 `ANTHROPIC_API_KEY` 時標示失敗，來源保留可重試。

## iOS 整合測試

`Packages/AppCore` 的 `ItineraryIntegrationTests` 會對本機 Supabase 呼叫 RPC（建 Trip、註冊 Place、提交行程、過期 revision、非成員被拒）。每次以隨機 Email 註冊兩個測試使用者，只在設定環境變數時執行：

```bash
BEARTRAVEL_TEST_SUPABASE_URL=http://127.0.0.1:54321 \
BEARTRAVEL_TEST_SUPABASE_ANON_KEY=<supabase status 的 ANON_KEY> \
swift test --package-path Packages/AppCore
```

## 雲端專案（首爾）

- 專案：`BeaRTravel`（`dchzimksdgxzjvzswzrh`，ap-northeast-2）。截至 2026-09-26，已套用至 `20260926000020`，`organize-inbox` 與更新後的 `delete-account` 已部署並顯示 ACTIVE、JWT 驗證開啟；未登入的整理請求回 401。這是部署與基本權限入口驗證，兩帳號與真機流程尚待驗收。既有設定已開放 `app` schema、關閉 Email 確認、密碼最短 8。
- 更新：`supabase db push`、`supabase functions deploy`；`supabase config push` 會把本機 `config.toml` 的 auth 設定一併推上去，推之前先看差異。
- App：Release build 連雲端，網址與 anon key 放在 `Config/Cloud.xcconfig.local`（gitignore）；Debug build 連本機。
- AI：`supabase secrets set ANTHROPIC_API_KEY=...` 後，匯入解析與 AI 助手才會運作。

## 部署到 Supabase 專案時

- 在專案的 API 設定把 `app` 加入 exposed schemas，用戶端以 `schema: 'app'` 呼叫 RPC。
- Auth → Providers → Email：關閉 **Confirm email**，密碼最短長度設 8（與 App 檢查一致）。
- 不要套用 `tests/support/` 下的檔案。
