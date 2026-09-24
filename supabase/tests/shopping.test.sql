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

select tests.login(:'viewer');
select tests.throws(format($$select app.add_shopping_item(%L, 'x')$$, :'trip_id'), 'PT403', 'viewer cannot add items');

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
