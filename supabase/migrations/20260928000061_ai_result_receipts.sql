-- 私人回答的待查看狀態；歷史資料沒有已讀追蹤，遷移時不重新提醒。
alter table app.ai_messages add column read_at timestamptz;
update app.ai_messages set read_at=created_at;
create function app.unread_ai_message_count(p_trip_id uuid) returns integer
language plpgsql security definer set search_path='' as $$
begin
 perform app.require_role(p_trip_id,array['owner','editor','viewer']::app.trip_role[]);
 return (select count(*)::integer from app.ai_messages
  where trip_id=p_trip_id and user_id=auth.uid() and status='answered' and read_at is null);
end; $$;
create function app.mark_ai_message_read(p_message_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 update app.ai_messages set read_at=coalesce(read_at,now())
  where id=p_message_id and user_id=auth.uid() and app.trip_role_of(trip_id) is not null;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
end; $$;
revoke all on function app.unread_ai_message_count(uuid),app.mark_ai_message_read(uuid) from public,anon;
grant execute on function app.unread_ai_message_count(uuid),app.mark_ai_message_read(uuid) to authenticated;
notify pgrst,'reload schema';
