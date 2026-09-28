alter table app.personal_ai_jobs drop constraint personal_ai_jobs_kind_check;
alter table app.personal_ai_jobs add constraint personal_ai_jobs_kind_check check(kind in ('prepare','parse','ask','extract','inbox','discover'));
