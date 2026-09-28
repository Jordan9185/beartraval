-- 本站附近結果的收藏與地址一起寫入。重開畫面或兩位旅伴同時加入不產生重複。
create function app.save_station_place(p_trip_id uuid,p_name text,p_address text default null,p_url text default null,p_summary text default null,p_category app.saved_category default 'place',p_operation_id uuid default null)
returns app.saved_places language plpgsql security definer set search_path='' as $$
declare saved app.saved_places; result jsonb;
begin
 perform app.require_role(p_trip_id,array['owner','editor']::app.trip_role[]);
 if nullif(btrim(p_name),'') is null or length(p_name)>500 or p_url is null or length(p_url)>2000 or p_url !~ '^https://[^[:space:]]+$' then
  raise exception 'INVALID_PLACE' using errcode='PT422'; end if;
 perform pg_advisory_xact_lock(hashtext(p_trip_id::text||'|'||btrim(p_name)||'|'||coalesce(nullif(btrim(p_address),''),'')||'|'||p_url));
 select s.* into saved from app.saved_places s join app.source_references r on r.id=s.source_id
 where s.trip_id=p_trip_id and s.status<>'dismissed' and s.raw_label=btrim(p_name)
   and coalesce(s.address_hint,'')=coalesce(nullif(btrim(p_address),''),'') and r.url=p_url limit 1;
 if found then
  if nullif(btrim(p_address),'') is null and (p_operation_id is null or saved.client_op_id is distinct from p_operation_id) then
   raise exception 'AMBIGUOUS_DUPLICATE' using errcode='PT409'; end if;
  perform app.set_saved_interest(saved.id,true);
  return saved;
 end if;
 result:=app.save_place(p_trip_id,p_name,p_category,null,jsonb_build_object('url',p_url,'summary',p_summary),p_operation_id);
 select * into saved from app.saved_places where id=(result->>'id')::uuid;
 if nullif(btrim(p_address),'') is not null then
  saved:=app.set_saved_address_hint(saved.id,p_address,p_url);
 end if;
 return saved;
end; $$;
revoke all on function app.save_station_place(uuid,text,text,text,text,app.saved_category,uuid) from public,anon;
grant execute on function app.save_station_place(uuid,text,text,text,text,app.saved_category,uuid) to authenticated;
notify pgrst,'reload schema';
