-- pg_stat_statements snapshot keyed by (db, role, queryid): run twice, delta = measured per-statement rate.
select now() at time zone 'utc' ts, d.datname, r.rolname, p.queryid, p.calls, p.rows, round(p.total_exec_time) exec_ms,
       p.shared_blks_read, p.wal_bytes, p.stats_since::timestamp(0)
from pg_stat_statements p join pg_database d on d.oid=p.dbid left join pg_roles r on r.oid=p.userid;
