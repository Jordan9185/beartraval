-- Edge Function 的 service_role 只需讀取已登記的圖片中繼資料。
grant select on app.inbox_assets to service_role;
