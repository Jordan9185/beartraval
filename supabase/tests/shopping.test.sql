-- Shopping: unscheduled until a purchase stop is confirmed; merchants are
-- "possible" with expiring evidence; purchase/undo events with buyer-or-owner undo.

\set owner  '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
\set viewer '00000000-0000-0000-0000-00000000000c'

set role authenticated;
select tests.login(:'owner');
select id as trip_id from app.create_trip('Hiroshima', '2026-10-01', '2026-10-01', 'Asia/Tokyo') \gset
select id as day_id from app.trip_days where trip_id = :'trip_id' \gset
select app.create_invite(:'trip_id', 'editor') as etoken \gset
select app.create_invite(:'trip_id', 'viewer') as vtoken \gset
select tests.login(:'editor');
select app.accept_invite(:'etoken');
select tests.login(:'viewer');
select app.accept_invite(:'vtoken');

-- AC-09: a new item is unscheduled.
select tests.login(:'editor');
select id as item_id from app.add_shopping_item(:'trip_id', 'ReFa CARAT', null, null, '22222222-2222-2222-2222-222222222222') \gset
select tests.ok((select planned_stop_id is null from app.shopping_items where id = :'item_id'), 'new item unscheduled');
select tests.ok((select id from app.add_shopping_item(:'trip_id', 'ReFa CARAT', null, null, '22222222-2222-2222-2222-222222222222')) = :'item_id',
                'retried add returns same item');
select tests.ok((select count(*) from app.shopping_interests where item_id = :'item_id') = 1, 'adder wants it');

select app.set_shopping_store_suggestions(:'item_id', '[{"name":"IVYNYU LAB","korean_name":"아이비뉴랩","address_local":"서울특별시 성동구 연무장길 1","search_query":"아이비뉴랩 성수","reason":"店面來源","source_url":"https://example.com/store"}]'::jsonb);
select tests.ok((select store_suggestions_checked and store_suggestions -> 0 ->> 'address_local' = '서울특별시 성동구 연무장길 1'
                   from app.shopping_items where id = :'item_id'), 'recognised store address persists on shopping item');
select tests.throws(format($$select app.set_shopping_store_suggestions(%L, '[{"name":"店面","search_query":"店面","reason":"線索","source_url":"http://example.com"}]'::jsonb)$$, :'item_id'),
                    'PT422', 'store suggestion requires an https source');

select tests.login(:'viewer');
select tests.throws(format($$select app.add_shopping_item(%L, 'x')$$, :'trip_id'), 'PT403', 'viewer cannot add items');
select tests.throws(format($$select app.set_shopping_store_suggestions(%L, '[]'::jsonb)$$, :'item_id'),
                    'PT403', 'viewer cannot change recognised store suggestions');

-- AC-10: merchant candidates carry evidence, never stock.
select tests.login(:'editor');
select (app.upsert_place('apple_mapkit', 'fukuya', 'Fukuya ReFa', 34.3935, 132.4640)).id as store \gset
select tests.throws(format($$select app.add_merchant_candidate(%L, %L, 'official_locator')$$, :'item_id', :'store'),
                    'PT422', 'official evidence needs a URL');
select app.add_merchant_candidate(:'item_id', :'store', 'poi_category', null, 'Apple 地圖搜尋「ReFa」');
select tests.ok((select inventory_status = 'unknown' and expires_at > now() + interval '29 days'
                   from app.merchant_candidates where item_id = :'item_id'), 'possible merchant, stock unknown, 30-day evidence');

-- Purchase stop via proposal links back to the item.
select id as pid from app.create_proposal(:'day_id', 0,
  format('{"place_id": %s, "raw_label": "ReFa @ Fukuya", "shopping_item_id": %s, "dwell_minutes": 30}',
         to_json(:'store'::text), to_json(:'item_id'::text))::jsonb) \gset
select tests.ok((app.confirm_proposal(:'pid')) ->> 'status' = 'confirmed', 'purchase stop confirmed');
select tests.ok((select kind = 'purchase' and shopping_item_id = :'item_id' from app.stops where day_id = :'day_id'), 'stop is a purchase stop');
select tests.ok((select planned_stop_id is not null from app.shopping_items where id = :'item_id'), 'item scheduled');
-- A second purchase stop for an already scheduled item is refused.
select id as pid2 from app.create_proposal(:'day_id', 1,
  format('{"place_id": %s, "raw_label": "ReFa again", "shopping_item_id": %s}',
         to_json(:'store'::text), to_json(:'item_id'::text))::jsonb) \gset
select tests.throws(format($$select app.confirm_proposal(%L)$$, :'pid2'), 'PT409', 'item already has a purchase stop');
select tests.ok((select count(*) from app.stops where shopping_item_id = :'item_id' and deleted_at is null) = 1, 'still one purchase stop');

-- AC-11: purchase and undo.
select tests.ok(app.record_purchase(:'item_id', true, '33333333-3333-3333-3333-333333333333') = 'purchased', 'editor marks purchased');
select tests.ok(app.record_purchase(:'item_id', true, '33333333-3333-3333-3333-333333333333') = 'purchased', 'retried purchase is idempotent');
select tests.ok((select count(*) from app.purchase_events where item_id = :'item_id') = 1, 'one purchase event');
select tests.ok((select count(*) from app.shopping_interests where item_id = :'item_id') = 1, 'wanting and buying stay separate');

select tests.login(:'viewer');
select tests.throws(format($$select app.record_purchase(%L, false)$$, :'item_id'), 'PT403', 'viewer cannot undo');

-- Owner can undo someone else's purchase; the log keeps both.
select tests.login(:'owner');
select tests.ok(app.record_purchase(:'item_id', false) = 'undone', 'owner undoes');
select tests.ok((select string_agg(type::text, ',' order by id) from app.purchase_events where item_id = :'item_id') = 'purchased,undone',
                'history kept');

-- A different editor cannot undo the buyer's purchase.
select tests.login(:'editor');
select app.record_purchase(:'item_id', true);
select id as item2 from app.add_shopping_item(:'trip_id', 'Momiji') \gset
select tests.login(:'owner');
select app.record_purchase(:'item2', true);
select tests.login(:'editor');
select tests.throws(format($$select app.record_purchase(%L, false)$$, :'item2'), 'PT403', 'non-buyer editor cannot undo');

-- Removing the purchase stop from the itinerary unschedules the item.
select tests.login(:'owner');
select app.commit_itinerary(:'day_id', 1, '[]');
select tests.ok((select planned_stop_id is null from app.shopping_items where id = :'item_id'), 'deleting stop unschedules item');

-- Images: only in the trip's own folder; viewers can't set them.
select tests.login(:'editor');
select tests.ok((app.set_shopping_image(:'item_id', :'trip_id' || '/item.jpg')).image_path = :'trip_id' || '/item.jpg',
                'editor sets an image in the trip folder');
select tests.throws(format($$select app.set_shopping_image(%L, '00000000-0000-0000-0000-000000000000/x.jpg')$$, :'item_id'),
                    'PT422', 'image from another trip folder rejected');
select tests.ok((app.set_shopping_image(:'item_id', null)).image_path is null, 'image can be removed');
select tests.login(:'viewer');
select tests.throws(format($$select app.set_shopping_image(%L, %L)$$, :'item_id', :'trip_id' || '/v.jpg'), 'PT403', 'viewer cannot set image');
select tests.ok(app.uuid_or_null('not-a-uuid') is null, 'bad folder name is not a trip');

-- Interest toggle ("想買") is per member; viewers can't.
select tests.login(:'owner');
select app.set_shopping_interest(:'item2', true);
select tests.ok((select count(*) from app.shopping_interests where item_id = :'item2') = 2, 'owner wants item2 too');
select app.set_shopping_interest(:'item2', false);
select tests.ok((select count(*) from app.shopping_interests where item_id = :'item2') = 1
                and (select count(*) from app.shopping_interests where item_id = :'item2' and user_id = :'owner') = 0,
                'owner removed only their own interest');
select tests.login(:'viewer');
select tests.throws(format($$select app.set_shopping_interest(%L, true)$$, :'item2'), 'PT403', 'viewer cannot mark interest');
select tests.throws(format($$select app.add_merchant_candidate(%L, %L, 'user')$$, :'item2', :'store'), 'PT403', 'viewer cannot add merchants');

-- Re-adding a merchant refreshes its evidence and restarts the 30 days (D8).
select tests.login(:'editor');
reset role;
update app.merchant_candidates set evidence_at = now() - interval '40 days', expires_at = now() - interval '10 days'
 where item_id = :'item_id' and place_id = :'store';
set role authenticated;
select app.add_merchant_candidate(:'item_id', :'store', 'official_locator', 'https://www.refa.net/shop/', '官方店鋪頁');
select tests.ok((select evidence_type = 'official_locator' and expires_at > now() + interval '29 days' and evidence_at > now() - interval '1 minute'
                   and inventory_status = 'unknown'
                   from app.merchant_candidates where item_id = :'item_id' and place_id = :'store'),
                'expired evidence refreshed, stock still unknown');
select tests.ok((select count(*) from app.merchant_candidates where item_id = :'item_id') = 1, 'no duplicate merchant row');

select tests.throws(format($$select app.add_shopping_item(%L, '   ')$$, :'trip_id'), 'PT422', 'blank item name rejected');

-- Purchase without an op id is idempotent by state; undo with nothing bought writes nothing.
select id as item3 from app.add_shopping_item(:'trip_id', 'Lemon candy') \gset
select tests.ok(app.record_purchase(:'item3', false) = 'undone'
                and (select count(*) from app.purchase_events where item_id = :'item3') = 0, 'undo of an unbought item writes nothing');
select app.record_purchase(:'item3', true);
select tests.ok(app.record_purchase(:'item3', true) = 'purchased'
                and (select count(*) from app.purchase_events where item_id = :'item3') = 1, 'second purchase tick is a no-op');

-- The buyer deleted their account (actor cleared): only the owner may undo.
reset role;
update app.purchase_events set actor_id = null where item_id = :'item3';
set role authenticated;
select tests.throws(format($$select app.record_purchase(%L, false)$$, :'item3'), 'PT403', 'editor cannot undo an anonymised purchase');
select tests.login(:'owner');
select tests.ok(app.record_purchase(:'item3', false) = 'undone', 'owner can undo an anonymised purchase');

-- A purchase stop can't point at another trip's item.
select id as other_trip from app.create_trip('Other', '2026-10-01', '2026-10-01', 'Asia/Tokyo') \gset
select id as other_item from app.add_shopping_item(:'other_trip', 'Elsewhere') \gset
select route_revision as rev from app.trip_days where id = :'day_id' \gset
select id as pid3 from app.create_proposal(:'day_id', :'rev',
  format('{"place_id": %s, "raw_label": "wrong trip", "shopping_item_id": %s}',
         to_json(:'store'::text), to_json(:'other_item'::text))::jsonb) \gset
select tests.throws(format($$select app.confirm_proposal(%L)$$, :'pid3'), 'PT404', 'item from another trip rejected');
