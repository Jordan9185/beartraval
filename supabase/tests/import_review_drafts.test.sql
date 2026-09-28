\set owner    '00000000-0000-0000-0000-00000000000a'
\set member   '00000000-0000-0000-0000-00000000000b'
set role authenticated;
select tests.login(:'owner');
select id as import_id from app.create_import('Seoul', '2026-10-01', '2026-10-02', 'Asia/Seoul', 'Day 1 광장시장') \gset
select tests.throws(format($$select app.save_import_review(%L, 'x', 0, '{}')$$, :'import_id'), 'PT409', '尚未解析不能保存確認草稿');
reset role;
set role service_role;
select app.begin_parse(:'import_id') as attempt \gset
select app.record_parse_result(:'import_id', :'attempt', 'parsed', '{"draft":{"days":[]}}', null, 'm');
reset role;
set role authenticated;
select tests.login(:'owner');

select app.get_import_review(:'import_id') as first \gset
select tests.ok((:'first'::jsonb->>'source_version') = :'attempt' and (:'first'::jsonb->'state') = 'null'::jsonb
  and (:'first'::jsonb->>'revision')::int = 0, '尚無草稿時回傳來源版本與空內容');
select app.save_import_review(:'import_id', :'attempt', 0, '{"items":[{"id":0,"decision":"a"}]}') as rev1 \gset
select tests.ok(:rev1 = 1, '首次保存版本 1');
select tests.throws(format($$select app.save_import_review(%L, %L, 0, '{"items":[]}')$$, :'import_id', :'attempt'), 'PT409', '另一裝置用舊版本保存被拒');
select tests.ok((app.get_import_review(:'import_id')->'state'->'items'->0->>'decision') = 'a', '先保存的選擇沒有被後寫覆蓋');
select app.save_import_review(:'import_id', :'attempt', 1, '{"items":[{"id":0,"decision":"b"}]}') as rev2 \gset
select tests.ok(:rev2 = 2 and (app.get_import_review(:'import_id')->'state'->'items'->0->>'decision') = 'b', '依最新版本保存後可讀回');
select tests.throws(format($$select app.save_import_review(%L, 'other-source', 2, '{}')$$, :'import_id'), 'PT409', '來源版本不符不寫入');
select tests.throws(format($$select app.save_import_review(%L, %L, 2, '[]')$$, :'import_id', :'attempt'), 'PT422', '內容必須是物件');

-- 私人草稿：其他帳號（含旅伴）讀不到也寫不了。
select tests.login(:'member');
select tests.throws(format($$select app.get_import_review(%L)$$, :'import_id'), 'PT404', '其他帳號讀不到匯入草稿');
select tests.throws(format($$select app.save_import_review(%L, %L, 2, '{}')$$, :'import_id', :'attempt'), 'PT404', '其他帳號不能寫入');
select tests.throws($$select * from app.import_review_drafts$$, '42501', '草稿表不直接開放');
select tests.login(:'owner');

-- 修改原文重新解析：舊草稿不再回傳，舊裝置晚到的保存被拒。
select app.update_import_text(:'import_id', 'Day 1 광장시장 10:00');
reset role;
set role service_role;
select app.begin_parse(:'import_id') as attempt2 \gset
select app.record_parse_result(:'import_id', :'attempt2', 'parsed', '{"draft":{"days":[]}}', null, 'm');
reset role;
set role authenticated;
select tests.login(:'owner');
select tests.ok((app.get_import_review(:'import_id')->'state') = 'null'::jsonb
  and (app.get_import_review(:'import_id')->>'source_version') = :'attempt2', '重新解析後舊草稿不套用');
select tests.throws(format($$select app.save_import_review(%L, %L, 2, '{}')$$, :'import_id', :'attempt'), 'PT409', '舊來源的晚到保存被拒');
select tests.ok(app.save_import_review(:'import_id', :'attempt2', 0, '{"items":[]}') = 1, '新來源從版本 1 重新開始');

-- 建立旅程後草稿不再回傳或寫入。
select app.commit_import(:'import_id', '[]');
select tests.ok((app.get_import_review(:'import_id')->'state') = 'null'::jsonb, '建立旅程後不回傳草稿');
select tests.throws(format($$select app.save_import_review(%L, %L, 1, '{}')$$, :'import_id', :'attempt2'), 'PT409', '建立旅程後不能再保存');
