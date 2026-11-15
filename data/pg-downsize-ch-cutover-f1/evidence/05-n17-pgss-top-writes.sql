-- Top 45 write statements on n17 by WAL bytes (all databases), with calls and rows.
select d.datname, r.rolname, p.queryid, p.calls, p.rows, round(p.total_exec_time/3600000) exec_h,
       pg_size_pretty(p.wal_bytes) wal, p.wal_bytes, p.stats_since::date since,
       left(regexp_replace(p.query, '\s+', ' ', 'g'), 260) q
from pg_stat_statements p join pg_database d on d.oid=p.dbid left join pg_roles r on r.oid=p.userid
where p.query ~* '^\s*(/\*.*?\*/\s*)*(insert|update|delete|merge|copy|truncate|create|refresh|alter|drop)' or p.query ~* '^\s*(/\*.*?\*/\s*)*with.*\m(insert|update|delete)\M'
order by p.wal_bytes desc limit 45;
