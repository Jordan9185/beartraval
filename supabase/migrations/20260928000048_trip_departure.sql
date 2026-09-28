-- 接任必須由受邀成員本人接受；提出移交不改角色，舊擁有者也不會自動退出。
create table app.ownership_offers (
 trip_id uuid primary key references app.trips(id) on delete cascade,
 from_user uuid not null references auth.users(id) on delete cascade,
 to_user uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);
alter table app.ownership_offers enable row level security;
grant select on app.ownership_offers to authenticated;
create policy ownership_offer_read on app.ownership_offers for select to authenticated
 using(app.trip_role_of(trip_id) is not null and auth.uid() in (from_user,to_user));
create function app.offer_trip_ownership(p_trip_id uuid,p_to uuid default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app.trips where id=p_trip_id for update;
 perform app.require_role(p_trip_id,array['owner']::app.trip_role[]);
 if p_to is null then delete from app.ownership_offers where trip_id=p_trip_id; return; end if;
 if p_to=auth.uid() or not exists(select 1 from app.trip_members where trip_id=p_trip_id and user_id=p_to and status='active' and role='editor') then
  raise exception 'INVALID_MEMBER' using errcode='PT422'; end if;
 insert into app.ownership_offers(trip_id,from_user,to_user) values(p_trip_id,auth.uid(),p_to)
 on conflict(trip_id) do update set from_user=excluded.from_user,to_user=excluded.to_user,created_at=now();
 perform app.bump_trip(p_trip_id,'member.changed',p_to);
end; $$;
create function app.respond_trip_ownership(p_trip_id uuid,p_from uuid,p_accept boolean) returns void
language plpgsql security definer set search_path='' as $$
declare offer app.ownership_offers;
begin
 perform 1 from app.trips where id=p_trip_id for update;
 perform app.require_role(p_trip_id,array['editor']::app.trip_role[]);
 select * into offer from app.ownership_offers where trip_id=p_trip_id and from_user=p_from and to_user=auth.uid() for update;
 if not found or not exists(select 1 from app.trips where id=p_trip_id and owner_id=p_from) then
  raise exception 'STALE_REVISION' using errcode='PT409'; end if;
 if p_accept then
  update app.trip_members set role='editor' where trip_id=p_trip_id and user_id=p_from;
  update app.trip_members set role='owner' where trip_id=p_trip_id and user_id=auth.uid();
  update app.trips set owner_id=auth.uid(),updated_at=now() where id=p_trip_id;
 end if;
 delete from app.ownership_offers where trip_id=p_trip_id;
 perform app.bump_trip(p_trip_id,'member.changed',auth.uid());
end; $$;
create function app.leave_trip(p_trip_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform 1 from app.trips where id=p_trip_id for update;
 perform app.require_role(p_trip_id,array['editor','viewer']::app.trip_role[]);
 update app.trip_members set status='removed' where trip_id=p_trip_id and user_id=auth.uid();
 delete from app.ownership_offers where trip_id=p_trip_id and to_user=auth.uid();
 perform app.bump_trip(p_trip_id,'member.changed',auth.uid());
end; $$;
-- 未完成分工回待認領；私人用品仍保留本人，不轉成共同用品。
create function app.release_departed_assignments() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status='active' and new.status<>'active' then
  update app.packing_items set carrier_id=case when carrier_id=new.user_id then null else carrier_id end,
   buyer_id=case when buyer_id=new.user_id then null else buyer_id end,revision=revision+1,updated_at=now()
   where trip_id=new.trip_id and shared and not packed and (carrier_id=new.user_id or buyer_id=new.user_id);
  update app.shopping_items set buyer_id=null,quantity_revision=quantity_revision+1,updated_at=now()
   where trip_id=new.trip_id and buyer_id=new.user_id and bought_quantity<desired_quantity;
  delete from app.ownership_offers where trip_id=new.trip_id and to_user=new.user_id;
 end if;
 return new;
end; $$;
create trigger release_departed_assignments after update of status on app.trip_members for each row execute function app.release_departed_assignments();
revoke all on function app.offer_trip_ownership(uuid,uuid),app.respond_trip_ownership(uuid,uuid,boolean),app.leave_trip(uuid) from public,anon;
grant execute on function app.offer_trip_ownership(uuid,uuid),app.respond_trip_ownership(uuid,uuid,boolean),app.leave_trip(uuid) to authenticated;
notify pgrst,'reload schema';

create or replace function app.set_member_role(p_trip_id uuid, p_user_id uuid, p_role app.trip_role) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform 1 from app.trips where id=p_trip_id for update;
  perform app.require_role(p_trip_id, array['owner']::app.trip_role[]);
  if p_role = 'owner' or p_user_id = auth.uid() then
    raise exception 'INVALID_ROLE' using errcode = 'PT422';
  end if;
  update app.trip_members set role = p_role
   where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.bump_trip(p_trip_id, 'member.changed', p_user_id);
end;
$$;

create or replace function app.remove_member(p_trip_id uuid, p_user_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  perform 1 from app.trips where id=p_trip_id for update;
  perform app.require_role(p_trip_id, array['owner']::app.trip_role[]);
  if p_user_id = auth.uid() then
    raise exception 'INVALID_ROLE' using errcode = 'PT422';
  end if;
  update app.trip_members set status = 'removed'
   where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.bump_trip(p_trip_id, 'member.changed', p_user_id);
end;
$$;
