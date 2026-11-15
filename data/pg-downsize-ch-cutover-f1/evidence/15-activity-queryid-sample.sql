-- One sample of (application_name, query_id) for non-idle client backends. Run repeatedly; the union maps queryid -> service
-- for every client that sets application_name. A blank name stays unmapped from this source.
select now() at time zone 'utc' ts, datname, usename, coalesce(nullif(application_name,''),'(blank)') app, client_addr, state, query_id,
       left(regexp_replace(query, '\s+', ' ', 'g'), 120) q
from pg_stat_activity where backend_type='client backend' and query_id is not null and pid <> pg_backend_pid() and application_name not like 'fm-pg-downsize%';
-- NOTE: the q column was dropped from the committed csv files (live statements carry literals); query_id is kept.
