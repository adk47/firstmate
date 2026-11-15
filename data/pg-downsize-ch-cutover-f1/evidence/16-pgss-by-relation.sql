-- pg_stat_statements folded to (database, role, kind, relation family). The relation is the first table named after
-- INSERT INTO / UPDATE / DELETE FROM (writes, including inside a CTE) or the first FROM (reads); generation suffixes _<digits> fold to _N.
-- Statements with no relation (SELECT $1, SET, BEGIN ...) fold to '(none)'. Lossy: evicted entries are not here.
with s as (
  select d.datname, r.rolname, p.*,
    regexp_replace(p.query, '\s+', ' ', 'g') q
  from pg_stat_statements p join pg_database d on d.oid=p.dbid left join pg_roles r on r.oid=p.userid),
k as (
  select *,
    case when q ~* '\m(insert\s+into|update|delete\s+from|merge\s+into|copy|truncate)\M\s+"?[a-z_]' and q !~* '^\s*(select|fetch|declare)' and q !~* 'for update' then 'write'
         when q ~* '^\s*create\s+temp' then 'write'
         when q ~* '^\s*(/\*.*?\*/\s*)*(select|with|fetch|declare|table|values)' then 'read'
         else 'other' end kind
  from s),
t as (
  select *,
    case kind
      when 'write' then coalesce(
          (regexp_match(q, '(?:insert\s+into|delete\s+from|merge\s+into|truncate(?:\s+table)?|copy)\s+(?:only\s+)?(?:"?public"?\.)?"?([a-zA-Z_][a-zA-Z0-9_]*)', 'i'))[1],
          (regexp_match(q, 'update\s+(?:only\s+)?(?:"?public"?\.)?"?([a-zA-Z_][a-zA-Z0-9_]*)', 'i'))[1],
          (regexp_match(q, 'create\s+temp\s+table\s+(?:if\s+not\s+exists\s+)?([a-zA-Z_][a-zA-Z0-9_]*)', 'i'))[1], '(none)')
      when 'read' then coalesce((regexp_match(q, '\mfrom\s+(?:only\s+)?(?:"?public"?\.)?"?([a-zA-Z_][a-zA-Z0-9_]*)', 'i'))[1], '(none)')
      else '(none)' end rel
  from k)
select datname, rolname, kind, regexp_replace(lower(rel), '_[0-9]+(_|$)', '_N\1') rel, count(*) stmts, sum(calls) calls, sum(rows) rows,
       round(sum(total_exec_time)/3600000) exec_h, sum(shared_blks_read) blks_read, pg_size_pretty(sum(wal_bytes)) wal, sum(wal_bytes) wal_bytes,
       min(stats_since)::date oldest
from t where kind <> 'other'
group by 1,2,3,4 having sum(rows) > 1000000 or sum(wal_bytes) > 1e9 or sum(total_exec_time) > 3.6e6
order by kind, sum(rows) desc;
