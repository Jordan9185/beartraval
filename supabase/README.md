# Supabase 後端

決策 D1：Supabase（Postgres + RLS + Realtime + Edge Functions）。設計見 [技術規劃 §3](../docs/planning/mvp-technical-plan.md)。

## 結構

| 路徑 | 內容 |
|---|---|
| `migrations/` | 資料庫 migration（依檔名順序套用） |
| `tests/` | SQL 測試與執行腳本 |
| `tests/support/supabase_shim.sql` | 在一般 Postgres 模擬 Supabase 的 `auth.uid()` 與角色，**只給測試用** |

## 權限模型

- 所有資料表在 `app` schema。用戶端只能 `select`，RLS 限制為該 Trip 的有效成員。
- 所有寫入都經由 RPC（`security definer`），在函式內檢查角色；直接 insert/update/delete 一律被拒。
- 行程寫入帶 `expected_route_revision`，不符回 `STALE_REVISION`，不寫入任何資料。
- 當日 `route_revision` 一改變（任何 RPC），觸發器就把該日未確認的 proposal 標為 `stale`。
- 地點一進入正式行程（stops），同 Trip 同地點的 Saved 自動標為 `added_to_itinerary`，不再出現在待加入清單。

## RPC

| 函式 | 權限 | 說明 |
|---|---|---|
| `create_trip(name, start_date, end_date, time_zone)` | 已登入 | 建 Trip、每日 TripDay、Owner 成員 |
| `upsert_place(provider, provider_place_id, name, latitude, longitude, name_local?, address?, country_code?)` | 已登入 | 註冊已確認的 POI；同一 provider id 已存在時回傳既有資料、不覆寫 |
| `create_import(trip_name, start_date, end_date, time_zone, raw_text)` | 已登入 | 建 ImportSession，保留原文 |
| `update_import_text(import_id, raw_text)` | 建立者 | 回到原文編輯；清除舊草稿 |
| `commit_import(import_id, days jsonb)` | 建立者 | 在同一交易建 Trip、各日 Stop；Place 須先 `upsert_place` |
| `record_parse_result(...)` | 僅 service_role | 由 `parse-import` Edge Function 寫入解析結果 |
| `commit_itinerary(day_id, expected_route_revision, stops jsonb)` | Owner／Editor | 以有序清單取代當日行程；回傳新 route_revision |
| `create_proposal(day_id, expected_route_revision, change jsonb, route_match jsonb)` | Owner／Editor | 建立加入行程的 proposal（地點須已確認）；不寫入 Stop |
| `confirm_proposal(proposal_id)` | Owner／Editor | 插入 Stop；當日已變更時回 `{"status":"stale"}` 且不寫入 |
| `reject_proposal(proposal_id)` | Owner／Editor | 取消 proposal |
| `save_place(trip_id, raw_label, category, place_id?, source jsonb?)` | Owner／Editor | 收藏到共同 Saved（不改行程）；同一 `canonical_url` 或同一地點回傳既有項目並記錄想去 |
| `set_saved_interest(saved_id, interested)` | Owner／Editor | 想去（成員集合） |
| `resolve_saved(saved_id, place_id)` / `dismiss_saved(saved_id)` | Owner／Editor | 補填地點／移除 |
| `create_invite(trip_id, role, expires_in, max_uses)` | Owner | 回傳一次性明文 token，DB 只存 SHA-256 |
| `revoke_invite(invite_id)` | Owner | |
| `accept_invite(token)` | 已登入 | 加入 Trip |
| `set_member_role(trip_id, user_id, role)` / `remove_member(trip_id, user_id)` | Owner | |
| `get_trip_changes(trip_id, since_revision)` | 成員 | 重連後補拉錯過的變更 |
| `set_display_name(name)` | 已登入 | 顯示名稱（只有共同 Trip 的成員看得到） |
| `invite_preview(token)` | 僅 service_role | 邀請預覽頁用：Trip 名稱、日期、邀請者、權限；不含行程 |

Realtime：訂閱 `app.trip_events` 的 postgres_changes（依 `trip_id` 過濾，UUID 用小寫字串），收到後依 revision 重新拉取；重新訂閱成功時以 `get_trip_changes` 補拉。

邀請預覽頁：`GET /functions/v1/invite?token=…`（Edge Function `invite`，公開）。「在 App 開啟」目前用 `beartravel://invite?token=…`；有網域後改成 Universal Link。

離線佇列：`save_place` 接受 `client_op_id`，重送時回傳第一次的結果，不會重複新增。

## 錯誤代碼

SQLSTATE `PTnnn` 會讓 PostgREST 回傳 HTTP `nnn`：

| SQLSTATE | 訊息 | HTTP |
|---|---|---|
| PT401 | `UNAUTHENTICATED` | 401 |
| PT403 | `FORBIDDEN_ROLE` | 403 |
| PT404 | `NOT_FOUND`、`INVITE_INVALID` | 404 |
| PT409 | `STALE_REVISION`、`ALREADY_COMMITTED`、`PROPOSAL_CLOSED`、`DUPLICATE_SAVED` | 409 |
| PT410 | `INVITE_EXPIRED`、`INVITE_REVOKED` | 410 |
| PT422 | `INVALID_SAVED`、`PLACE_UNRESOLVED`、`EMPTY_TEXT`、`DATE_OUTSIDE_TRIP`、`INVALID_PLACE`、`INVALID_DATES`、`INVALID_TIME_ZONE`、`INVALID_STOPS`、`PLACE_NOT_FOUND`、`STOP_NOT_IN_DAY`、`INVALID_ROLE` | 422 |

## 測試

需要 Postgres 16+ 的 `initdb`、`pg_ctl`、`psql`（不需要 Docker）：

```
supabase/tests/run.sh
```

會建立暫時的資料庫，套用 shim 與 migration，每個 `*.test.sql` 在獨立資料庫執行，最後跑兩個連線同時提交的並發測試。CI：`.github/workflows/db-tests.yml`。

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

## iOS 整合測試

`Packages/AppCore` 的 `ItineraryIntegrationTests` 會對本機 Supabase 呼叫 RPC（建 Trip、註冊 Place、提交行程、過期 revision、非成員被拒）。每次以隨機 Email 註冊兩個測試使用者，只在設定環境變數時執行：

```bash
BEARTRAVEL_TEST_SUPABASE_URL=http://127.0.0.1:54321 \
BEARTRAVEL_TEST_SUPABASE_ANON_KEY=<supabase status 的 ANON_KEY> \
swift test --package-path Packages/AppCore
```

## 部署到 Supabase 專案時

- 在專案的 API 設定把 `app` 加入 exposed schemas，用戶端以 `schema: 'app'` 呼叫 RPC。
- Auth → Providers → Email：關閉 **Confirm email**，密碼最短長度設 8（與 App 檢查一致）。
- 不要套用 `tests/support/` 下的檔案。
