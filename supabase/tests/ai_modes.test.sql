\set owner '00000000-0000-0000-0000-00000000000a'
\set editor '00000000-0000-0000-0000-00000000000b'
set role authenticated;
select tests.login(:'owner');
select app.set_ai_provider('claude_api');
select tests.ok((select provider='claude_api' from app.ai_preferences),'本人明確選擇模式');
select tests.login(:'editor');
select tests.ok((select count(*)=0 from app.ai_preferences),'不讀取他人模式');
reset role;
grant usage on schema tests to service_role;
grant execute on all functions in schema tests to service_role;
set role service_role;
select id as cloud from app.enqueue_personal_ai(:'owner','extract','{}','{"ai_provider":"claude_api"}','cloud') \gset
select tests.ok((app.claim_personal_ai(:'owner')).id is null,'Mac 不領取 Claude 工作');
select (app.claim_claude_ai(:'cloud')).id as claimed \gset
select tests.ok(:'claimed'=:'cloud','Cloud 領取正確工作');
select tests.ok((app.claim_claude_ai(:'cloud')).id is null,'Cloud 不重複領取');
select id as local from app.enqueue_personal_ai(:'owner','extract','{}','{"ai_provider":"local_gpt"}','local') \gset
select tests.ok((app.claim_personal_ai(:'owner')).id=:'local','Mac 仍領取訂閱工作');
select tests.ok((app.enqueue_personal_ai(:'owner','extract','{}','{"ai_provider":"claude_api"}','cloud')).id=:'cloud','同工作沿用原模式不重跑');
