-- Live sessions on n17 by database, role, application_name and client address (point-in-time).
select datname, usename, coalesce(nullif(application_name,''),'(blank)') app, client_addr, count(*) n,
       count(*) filter (where state='active') active, count(*) filter (where state like 'idle in%') idle_in_txn
from pg_stat_activity where backend_type='client backend' group by 1,2,3,4 order by n desc;
