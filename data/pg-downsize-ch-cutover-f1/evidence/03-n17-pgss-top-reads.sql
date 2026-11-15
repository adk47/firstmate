-- Top 40 read statements on n17 by rows returned (all databases), with calls, exec hours and blocks read.
select d.datname, r.rolname, p.queryid, p.calls, p.rows, round(p.total_exec_time/3600000) exec_h,
       p.shared_blks_read blks_read, p.stats_since::date since,
       left(regexp_replace(p.query, '\s+', ' ', 'g'), 260) q
from pg_stat_statements p join pg_database d on d.oid=p.dbid left join pg_roles r on r.oid=p.userid
where p.query ~* '^\s*(/\*.*?\*/\s*)*(select|with|fetch|declare)' and p.query !~* '^\s*(/\*.*?\*/\s*)*with.*\m(insert|update|delete)\M'
order by p.rows desc limit 40;
