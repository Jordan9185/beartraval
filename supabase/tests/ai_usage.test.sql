-- Per-user AI quota: counts per kind, stops at the hourly limit, other users unaffected.

\set a '00000000-0000-0000-0000-00000000000a'
\set b '00000000-0000-0000-0000-00000000000b'

set role authenticated;
select tests.throws($$select app.consume_ai_quota('parse')$$, 'PT401', 'anonymous caller rejected');
select tests.login(:'a');
select tests.throws($$select app.consume_ai_quota('other')$$, 'PT422', 'unknown kind rejected');
select tests.ok(bool_and(app.consume_ai_quota('parse')), 'first 10 parses allowed') from generate_series(1, 10);
select tests.ok(not app.consume_ai_quota('parse'), '11th parse in an hour refused');
select tests.ok(app.consume_ai_quota('ask'), 'other kinds counted separately');
select tests.login(:'b');
select tests.ok(app.consume_ai_quota('parse'), 'other users unaffected');
select tests.throws($$select * from app.ai_usage$$, '42501', 'usage table not readable by clients');
