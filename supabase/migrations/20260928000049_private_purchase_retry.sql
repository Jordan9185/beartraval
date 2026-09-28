-- 保留四參數舊呼叫方式，新增重送識別，避免斷線後重複更新數量。
alter table app.personal_purchases add column last_operation_id uuid;
drop function app.set_personal_purchase(uuid,integer,integer,integer);
create function app.set_personal_purchase(p_id uuid,p_expected_revision integer,p_desired integer,p_bought integer,p_operation_id uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare item app.personal_purchases;
begin
 select * into item from app.personal_purchases where id=p_id and owner_id=auth.uid() for update;
 if not found then raise exception 'NOT_FOUND' using errcode='PT404'; end if;
 if p_operation_id is not null and p_operation_id=item.last_operation_id then return; end if;
 if item.revision is distinct from p_expected_revision then raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 if p_desired is null or p_bought is null or p_desired not between 1 and 999 or p_bought not between 0 and 999 then raise exception 'INVALID_ITEM' using errcode='PT422'; end if;
 update app.personal_purchases set desired_quantity=p_desired,bought_quantity=p_bought,revision=revision+1,last_operation_id=p_operation_id where id=item.id;
end; $$;
revoke all on function app.set_personal_purchase(uuid,integer,integer,integer,uuid) from public,anon;
grant execute on function app.set_personal_purchase(uuid,integer,integer,integer,uuid) to authenticated;
notify pgrst,'reload schema';
