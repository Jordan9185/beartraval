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

## RPC

| 函式 | 權限 | 說明 |
|---|---|---|
| `create_trip(name, start_date, end_date, time_zone)` | 已登入 | 建 Trip、每日 TripDay、Owner 成員 |
| `upsert_place(provider, provider_place_id, name, latitude, longitude, name_local?, address?, country_code?)` | 已登入 | 註冊已確認的 POI；同一 provider id 已存在時回傳既有資料、不覆寫 |
| `commit_itinerary(day_id, expected_route_revision, stops jsonb)` | Owner／Editor | 以有序清單取代當日行程；回傳新 route_revision |
| `create_invite(trip_id, role, expires_in, max_uses)` | Owner | 回傳一次性明文 token，DB 只存 SHA-256 |
| `revoke_invite(invite_id)` | Owner | |
| `accept_invite(token)` | 已登入 | 加入 Trip |
| `set_member_role(trip_id, user_id, role)` / `remove_member(trip_id, user_id)` | Owner | |
| `get_trip_changes(trip_id, since_revision)` | 成員 | 重連後補拉錯過的變更 |

Realtime：訂閱 `app.trip_events` 的 postgres_changes（依 `trip_id` 過濾），收到後依 revision 重新拉取。

## 錯誤代碼

SQLSTATE `PTnnn` 會讓 PostgREST 回傳 HTTP `nnn`：

| SQLSTATE | 訊息 | HTTP |
|---|---|---|
| PT401 | `UNAUTHENTICATED` | 401 |
| PT403 | `FORBIDDEN_ROLE` | 403 |
| PT404 | `NOT_FOUND`、`INVITE_INVALID` | 404 |
| PT409 | `STALE_REVISION` | 409 |
| PT410 | `INVITE_EXPIRED`、`INVITE_REVOKED` | 410 |
| PT422 | `INVALID_PLACE`、`INVALID_DATES`、`INVALID_TIME_ZONE`、`INVALID_STOPS`、`PLACE_NOT_FOUND`、`STOP_NOT_IN_DAY`、`INVALID_ROLE` | 422 |

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
