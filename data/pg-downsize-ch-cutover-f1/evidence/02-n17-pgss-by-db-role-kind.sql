-- pg_stat_statements aggregated by database, role and statement kind (n17 primary).
-- kind is derived from the leading keyword of the normalised text. Entries evicted since reset are NOT here (see dealloc in 01).
with s as (
  select d.datname, r.rolname,
    case
      when q ~* '^\s*(/\*.*?\*/\s*)*(select|with|values|table|fetch|declare|show|explain)' and q !~* '\m(insert|update|delete|merge)\M.*\m(into|set|from)\M' then 'read'
      when q ~* '^\s*(/\*.*?\*/\s*)*(insert|update|delete|merge|copy|truncate)' then 'write'
      when q ~* '^\s*(/\*.*?\*/\s*)*with' then 'write_cte'
      when q ~* '^\s*(/\*.*?\*/\s*)*(create|drop|alter|analyze|vacuum|reindex|refresh|cluster|comment|grant|revoke|lock)' then 'ddl_maint'
      when q ~* '^\s*(/\*.*?\*/\s*)*(begin|commit|rollback|set|reset|savepoint|release|start|discard|deallocate|prepare|execute|listen|notify|unlisten|call|do)' then 'txn_util'
      else 'other' end as kind,
    calls, rows, total_exec_time, shared_blks_read, shared_blks_hit, shared_blks_dirtied, shared_blks_written, wal_bytes, temp_blks_written, stats_since
  from (select *, query as q from pg_stat_statements) p
  join pg_database d on d.oid=p.dbid left join pg_roles r on r.oid=p.userid)
select datname, rolname, kind, count(*) stmts, sum(calls) calls, sum(rows) rows, round(sum(total_exec_time)/3600000) exec_h,
       sum(shared_blks_read) blks_read, sum(shared_blks_hit) blks_hit, pg_size_pretty(sum(wal_bytes)) wal, sum(wal_bytes) wal_bytes, min(stats_since)::date oldest
from s group by 1,2,3 order by sum(total_exec_time) desc;
