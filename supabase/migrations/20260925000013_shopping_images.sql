-- Shopping item images (spec §3.6: 網址／圖片／備註可選).
--
-- Images live in the private "shopping-images" bucket at <trip_id>/<file>.
-- Only members of that trip can read them; owners and editors can upload and
-- delete. The item keeps the object path; the app shows it with a signed URL.

alter table app.shopping_items
  add column image_path text check (image_path is null or length(image_path) <= 300);

-- Text to uuid without raising, for storage paths that aren't ours.
create function app.uuid_or_null(p text) returns uuid
language plpgsql immutable
set search_path = ''
as $$
begin
  return p::uuid;
exception when others then
  return null;
end;
$$;

create function app.set_shopping_image(p_item_id uuid, p_image_path text) returns app.shopping_items
language plpgsql security definer
set search_path = ''
as $$
declare
  i app.shopping_items;
begin
  select * into i from app.shopping_items where id = p_item_id and deleted_at is null;
  if not found then
    raise exception 'NOT_FOUND' using errcode = 'PT404';
  end if;
  perform app.require_role(i.trip_id, array['owner', 'editor']::app.trip_role[]);
  -- The image must be in this trip's folder, so one trip can't point at another's files.
  if p_image_path is not null and split_part(p_image_path, '/', 1) <> i.trip_id::text then
    raise exception 'INVALID_IMAGE' using errcode = 'PT422';
  end if;
  update app.shopping_items set image_path = p_image_path, updated_at = now()
   where id = p_item_id returning * into i;
  perform app.bump_trip(i.trip_id, 'shopping.changed', i.id);
  return i;
end;
$$;

revoke execute on function app.set_shopping_image(uuid, text) from public, anon;
grant execute on function app.set_shopping_image(uuid, text) to authenticated;
grant execute on function app.uuid_or_null(text) to authenticated;

-- Storage exists on Supabase but not in the plain-Postgres test harness.
do $$
begin
  if to_regclass('storage.objects') is null then
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('shopping-images', 'shopping-images', false, 5242880, array['image/jpeg', 'image/png', 'image/heic', 'image/webp'])
  on conflict (id) do nothing;

  execute $p$
    create policy shopping_images_read on storage.objects for select to authenticated
      using (bucket_id = 'shopping-images'
             and app.trip_role_of(app.uuid_or_null((storage.foldername(name))[1])) is not null)
  $p$;
  execute $p$
    create policy shopping_images_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'shopping-images'
                  and app.trip_role_of(app.uuid_or_null((storage.foldername(name))[1])) in ('owner', 'editor'))
  $p$;
  execute $p$
    create policy shopping_images_delete on storage.objects for delete to authenticated
      using (bucket_id = 'shopping-images'
             and app.trip_role_of(app.uuid_or_null((storage.foldername(name))[1])) in ('owner', 'editor'))
  $p$;
end;
$$;
