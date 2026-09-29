# 資料庫連線交接補充

本文件補足先前交接缺少的憑證帶入方式。沒有保存任何密碼，也不代表雲端部署已完成。

## 專案與環境

- 專案：BeaRTravel；project ref：`dchzimksdgxzjvzswzrh`；區域：`ap-northeast-2`。
- 本機 checkout：`/Users/user/beartraval`；`supabase/.temp/project-ref` 本次核對指向上述專案。
- 本次錯誤中的雲端 pooler：`aws-0-ap-northeast-2.pooler.supabase.com`，資料庫 `postgres`。連線埠與完整連線設定以 Dashboard 的 Connect 為準，不從錯誤訊息猜測。
- Debug App 使用本機 Supabase；Release 使用 `Config/Cloud.xcconfig.local`。App 設定不是 CLI 資料庫登入憑證。
- CLI access token、App anon key、service role key、App 登入密碼都不能代替資料庫的 `postgres` 密碼。

## 這次錯誤表示什麼

`cli_login_postgres` 是 CLI 的暫時登入角色。`SQLSTATE 28P01` 表示登入驗證失敗；這次命令尚未進入 migration 套用階段，不代表 SQL migration 有錯，也不能據此判定其他先前部署的結果。

Supabase 官方記錄了暫時角色／pooler 憑證快取造成免密流程失敗的情況。可以改由正確的資料庫密碼，透過 `SUPABASE_DB_PASSWORD` 明確提供；單憑這段 log 無法確認是快取問題或其他憑證問題。

2026-09-29 本次核對：Codex 工具程序沒有非空的 `SUPABASE_DB_PASSWORD`。這不代表其他終端或 Claude 程序也沒有。尚未驗證任何密碼或重新嘗試雲端登入。

## 安全帶入與只讀確認

持有資料庫密碼的人可在本機互動式 **zsh 終端**執行以下步驟。輸入不顯示，實際密碼不寫進命令歷史；不要把密碼貼到聊天、文件、指令參數或版控。

```zsh
cd /Users/user/beartraval
set +x
read -rs 'SUPABASE_DB_PASSWORD?Supabase 資料庫密碼：'
print
export SUPABASE_DB_PASSWORD
if [[ -n "$SUPABASE_DB_PASSWORD" ]]; then
  supabase migration list --linked
  # 上一步成功後，才執行下一行預覽；不套用 migration。
  # supabase db push --linked --dry-run --skip-vault
fi
unset SUPABASE_DB_PASSWORD
```

- 上述環境變數只傳給同一終端之後啟動的子程序；不能自動傳進已開啟的 Codex／Claude 或另一個終端。若交由 agent 執行，必須由其啟動環境或既有安全憑證機制帶入；不能假設同一台 Mac 就共享環境變數。
- `unset` 之後需重新安全帶入才能再次操作。既有安全儲存機制若已配置，可直接使用，不為排錯把秘密另存 repo。
- 若不知道現有密碼，需由專案擁有者透過既有密碼管理方式取得；不得由 agent 猜密碼、索取聊天明文、擅自重設密碼或刪除暫時角色。
- 若明確提供正確密碼仍失敗，先核對 Dashboard 的專案與連線資訊，再依官方文件檢查憑證快取／密碼輪替問題；不要無限重試或用 migration repair 掩蓋登入問題。

## 部署交接狀態

Claude 在既有交接記錄：2026-09-29 曾完成 dry-run，當時雲端待套 37–64；後續又新增 migration 65。這是歷史檢查點，不能直接當成現在雲端狀態。

恢復連線後，先以 `migration list --linked` 核對當前遠端版本，再以 dry-run 列出實際待套清單。此次補充沒有執行連線、migration、Edge 部署、密碼變更或 worker 重啟。正式部署仍依使用者授權及主交接順序進行，不只更新 App。

## 參考

- [Supabase CLI 暫時角色驗證／pooler 快取問題](https://supabase.com/docs/guides/troubleshooting/supabase-cli-failed-sasl-auth-or-invalid-scram-server-final-message)
- [Postgres 密碼驗證失敗](https://supabase.com/docs/guides/troubleshooting/fatal-password-authentication-failed)
- [主要實作交接](2026-09-28-rebuild-v1-implementation-handoff.md)
- [Claude 接續工作](2026-09-28-claude-remaining-work.md)
