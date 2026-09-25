-- 本機示範資料：首爾 5 天（從今天起算）。只用於本機開發，不要套用到雲端。
--
--   docker exec -i supabase_db_beartraval psql -U postgres -v user_id=<auth.users.id> < supabase/demo/seoul-5-days.sql
--
-- 全部透過正式 RPC 以該使用者身分寫入，權限、revision、去重規則照常運作。

\set ON_ERROR_STOP 1
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'user_id', 'role', 'authenticated')::text, true);

select id as trip_id from app.create_trip('首爾 5 天', current_date, current_date + 4, 'Asia/Seoul') \gset
select id as d1 from app.trip_days where trip_id = :'trip_id' and display_order = 0 \gset
select id as d2 from app.trip_days where trip_id = :'trip_id' and display_order = 1 \gset
select id as d3 from app.trip_days where trip_id = :'trip_id' and display_order = 2 \gset
select id as d4 from app.trip_days where trip_id = :'trip_id' and display_order = 3 \gset
select id as d5 from app.trip_days where trip_id = :'trip_id' and display_order = 4 \gset

-- 地點（座標為概略值）
select (app.upsert_place('apple_mapkit', 'demo-hotel', 'Nine Tree Premier Hotel Myeongdong II', 37.5634, 126.9837, '나인트리 프리미어 호텔 명동2', '서울특별시 중구 명동', 'KR')).id as hotel \gset
select (app.upsert_place('apple_mapkit', 'demo-namsan', 'N Seoul Tower', 37.5512, 126.9882, 'N서울타워', '서울특별시 용산구 남산공원길 105', 'KR')).id as namsan \gset
select (app.upsert_place('apple_mapkit', 'demo-kyoja', 'Myeongdong Kyoja', 37.5625, 126.9856, '명동교자 본점', '서울특별시 중구 명동10길 29', 'KR')).id as kyoja \gset
select (app.upsert_place('apple_mapkit', 'demo-oliveyoung', 'Olive Young Myeongdong Flagship', 37.5637, 126.9854, '올리브영 명동 플래그십', '서울특별시 중구 명동길 53', 'KR')).id as oliveyoung \gset
select (app.upsert_place('apple_mapkit', 'demo-gyeongbok', 'Gyeongbokgung Palace', 37.5796, 126.9770, '경복궁', '서울특별시 종로구 사직로 161', 'KR')).id as gyeongbok \gset
select (app.upsert_place('apple_mapkit', 'demo-bukchon', 'Bukchon Hanok Village', 37.5826, 126.9831, '북촌한옥마을', '서울특별시 종로구 계동길 37', 'KR')).id as bukchon \gset
select (app.upsert_place('apple_mapkit', 'demo-gwangjang', 'Gwangjang Market', 37.5700, 126.9996, '광장시장', '서울특별시 종로구 창경궁로 88', 'KR')).id as gwangjang \gset
select (app.upsert_place('apple_mapkit', 'demo-ddp', 'Dongdaemun Design Plaza', 37.5665, 127.0092, '동대문디자인플라자', '서울특별시 중구 을지로 281', 'KR')).id as ddp \gset
select (app.upsert_place('apple_mapkit', 'demo-tosokchon', 'Tosokchon Samgyetang', 37.5781, 126.9716, '토속촌 삼계탕', '서울특별시 종로구 자하문로5길 5', 'KR')).id as tosokchon \gset
select (app.upsert_place('apple_mapkit', 'demo-seoulforest', 'Seoul Forest', 37.5444, 127.0374, '서울숲', '서울특별시 성동구 뚝섬로 273', 'KR')).id as forest \gset
select (app.upsert_place('apple_mapkit', 'demo-onion', 'Onion Seongsu', 37.5447, 127.0584, '어니언 성수', '서울특별시 성동구 아차산로9길 8', 'KR')).id as onion \gset
select (app.upsert_place('apple_mapkit', 'demo-musinsa', 'Musinsa Standard Seongsu', 37.5430, 127.0560, '무신사 스탠다드 성수', '서울특별시 성동구 성수동2가', 'KR')).id as musinsa \gset
select (app.upsert_place('apple_mapkit', 'demo-hongdae', 'Hongik Univ. Station', 37.5572, 126.9245, '홍대입구역', '서울특별시 마포구 양화로 160', 'KR')).id as hongdae \gset
select (app.upsert_place('apple_mapkit', 'demo-yeonnam', 'Gyeongui Line Forest Park', 37.5625, 126.9215, '연남동 경의선숲길', '서울특별시 마포구 연남동', 'KR')).id as yeonnam \gset
select (app.upsert_place('apple_mapkit', 'demo-mangwon', 'Mangwon Market', 37.5560, 126.9060, '망원시장', '서울특별시 마포구 포은로8길 14', 'KR')).id as mangwon \gset
select (app.upsert_place('apple_mapkit', 'demo-coex', 'Starfield Library COEX', 37.5100, 127.0600, '별마당도서관', '서울특별시 강남구 영동대로 513', 'KR')).id as coex \gset
select (app.upsert_place('apple_mapkit', 'demo-lotte', 'Lotte World Tower Seoul Sky', 37.5126, 127.1025, '롯데월드타워 서울스카이', '서울특별시 송파구 올림픽로 300', 'KR')).id as lotte \gset
select (app.upsert_place('apple_mapkit', 'demo-icn', 'Incheon International Airport T1', 37.4492, 126.4510, '인천국제공항 제1터미널', '인천광역시 중구 공항로 272', 'KR')).id as icn \gset
select (app.upsert_place('apple_mapkit', 'demo-layered', 'Cafe Layered Yeonnam', 37.5609, 126.9230, '카페 레이어드 연남', '서울특별시 마포구 연남동', 'KR')).id as layered \gset
select (app.upsert_place('apple_mapkit', 'demo-tongin', 'Tongin Market', 37.5808, 126.9696, '통인시장', '서울특별시 종로구 자하문로15길 18', 'KR')).id as tongin \gset
select (app.upsert_place('apple_mapkit', 'demo-lottedf', 'Lotte Duty Free Myeongdong', 37.5650, 126.9810, '롯데면세점 명동본점', '서울특별시 중구 남대문로 81', 'KR')).id as lottedf \gset

-- Day 1：抵達、明洞（步行）
select app.commit_itinerary(:'d1', 0, format($$[
  {"place_id": %s, "raw_label": "飯店 check-in", "start_time": "15:00", "dwell_minutes": 30, "fixed": true},
  {"place_id": %s, "raw_label": "N首爾塔看夕陽", "start_time": "16:30", "dwell_minutes": 90},
  {"place_id": %s, "raw_label": "明洞餃子晚餐", "start_time": "18:30", "dwell_minutes": 60},
  {"raw_label": "明洞夜市逛逛（地點待確認）"}
]$$, to_json(:'hotel'::text), to_json(:'namsan'::text), to_json(:'kyoja'::text))::jsonb);

-- Day 2：宮殿與市場（大眾運輸 → Apple 在韓國算不出，示範「無法估算」與外開）
select app.commit_itinerary(:'d2', 0, format($$[
  {"place_id": %s, "raw_label": "景福宮", "start_time": "09:30", "dwell_minutes": 120},
  {"place_id": %s, "raw_label": "北村韓屋村", "start_time": "11:45", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "廣藏市場午餐", "start_time": "13:30", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "DDP", "start_time": "15:30", "dwell_minutes": 90},
  {"place_id": %s, "raw_label": "土俗村蔘雞湯（已訂位）", "start_time": "19:00", "dwell_minutes": 60, "fixed": true}
]$$, to_json(:'gyeongbok'::text), to_json(:'bukchon'::text), to_json(:'gwangjang'::text), to_json(:'ddp'::text), to_json(:'tosokchon'::text))::jsonb);

-- Day 3：聖水洞（步行）
select app.commit_itinerary(:'d3', 0, format($$[
  {"place_id": %s, "raw_label": "首爾林散步", "start_time": "10:00", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "Onion 早午餐", "start_time": "11:30", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "Musinsa Standard", "start_time": "13:30", "dwell_minutes": 45},
  {"raw_label": "IG 看到的選品店（店名待確認）"}
]$$, to_json(:'forest'::text), to_json(:'onion'::text), to_json(:'musinsa'::text))::jsonb);

-- Day 4：弘大、延南、望遠（步行）
select app.commit_itinerary(:'d4', 0, format($$[
  {"place_id": %s, "raw_label": "弘大", "start_time": "11:00", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "延南洞京義線林道", "start_time": "12:30", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "望遠市場", "start_time": "14:30", "dwell_minutes": 60}
]$$, to_json(:'hongdae'::text), to_json(:'yeonnam'::text), to_json(:'mangwon'::text))::jsonb);

-- Day 5：江南、樂天塔、機場（開車）
select app.commit_itinerary(:'d5', 0, format($$[
  {"place_id": %s, "raw_label": "飯店 check-out", "start_time": "10:00", "dwell_minutes": 20, "fixed": true},
  {"place_id": %s, "raw_label": "星空圖書館", "start_time": "11:30", "dwell_minutes": 60},
  {"place_id": %s, "raw_label": "樂天世界塔 Seoul Sky", "start_time": "14:00", "dwell_minutes": 90},
  {"place_id": %s, "raw_label": "仁川機場 KE 691 21:40 起飛", "start_time": "19:00", "fixed": true}
]$$, to_json(:'hotel'::text), to_json(:'coex'::text), to_json(:'lotte'::text), to_json(:'icn'::text))::jsonb);

reset role;
update app.trip_days set transport_mode = 'walking' where id in (:'d1', :'d3', :'d4');
update app.trip_days set transport_mode = 'transit' where id = :'d2';
update app.trip_days set transport_mode = 'driving' where id = :'d5';
set local role authenticated;

-- Saved：兩間已確認、一間在大眾運輸日附近、一筆地點未確認
select app.save_place(:'trip_id', '올리브영 명동 플래그십', 'shop', :'oliveyoung',
  '{"type": "share", "url": "https://www.threads.net/@seoul.beauty/post/DemoOlive", "canonical_url": "https://threads.com/@seoul.beauty/post/DemoOlive", "summary": "明洞旗艦店，面膜買一送一"}');
select app.save_place(:'trip_id', '카페 레이어드 연남', 'cafe', :'layered',
  '{"type": "share", "url": "https://www.instagram.com/p/DemoLayered/", "canonical_url": "https://instagram.com/p/DemoLayered", "summary": "司康很有名，早點去"}');
select app.save_place(:'trip_id', '통인시장', 'eat', :'tongin',
  '{"type": "url", "url": "https://maps.apple.com/?ll=37.5808,126.9696&q=Tongin%20Market", "canonical_url": "https://maps.apple.com/?ll=37.5808,126.9696&q=Tongin%20Market"}');
select app.save_place(:'trip_id', 'IG 上看到的烤肉店（名稱不明）', 'eat', null,
  '{"type": "share", "url": "https://www.instagram.com/p/DemoBBQ/", "canonical_url": "https://instagram.com/p/DemoBBQ"}');

-- Shopping：未安排（有可能販售的店）、今天要買（Purchase Stop）、已購買
select id as refa from app.add_shopping_item(:'trip_id', 'ReFa CARAT RAY', '媽媽指定', null) \gset
select app.add_merchant_candidate(:'refa', :'lottedf', 'poi_category', null, 'Apple 地圖搜尋「ReFa 명동」');

select id as mask from app.add_shopping_item(:'trip_id', '韓國面膜', null, null) \gset
select app.add_merchant_candidate(:'mask', :'oliveyoung', 'poi_category', null, 'Apple 地圖搜尋「올리브영 명동」');
select id as pid from app.create_proposal(:'d1', 1, format($$
  {"place_id": %s, "raw_label": "Olive Young 買面膜", "before_stop_id": %s, "dwell_minutes": 30, "shopping_item_id": %s}
$$, to_json(:'oliveyoung'::text), to_json((select id from app.stops where day_id = :'d1' and raw_label = '明洞餃子晚餐')::text), to_json(:'mask'::text))::jsonb) \gset
select app.confirm_proposal(:'pid');

select id as almond from app.add_shopping_item(:'trip_id', '蜂蜜奶油杏仁', null, null) \gset
select app.record_purchase(:'almond', true);

commit;
select 'seeded trip ' || :'trip_id';
