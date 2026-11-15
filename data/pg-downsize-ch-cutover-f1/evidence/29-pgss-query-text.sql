-- Full normalised text (first 900 chars) of the statements that dominate the A->B window,
-- so each can be matched to the code that issues it.
select d.datname, r.rolname, p.queryid, p.calls, p.rows, round(p.total_exec_time/3.6e6) exec_h,
       pg_size_pretty(p.wal_bytes) wal, p.stats_since::timestamp(0),
       left(regexp_replace(p.query, '\s+', ' ', 'g'), 900) q
from pg_stat_statements p join pg_database d on d.oid=p.dbid left join pg_roles r on r.oid=p.userid
where p.queryid in (-3793548785045396670,-3206784974791733282,1094077187582001326,-1553054039769019196,
  2214863175886206164,-2037529466112218811,-709929211709219153,-8850958813059235032,-5173349918025204224,
  3762482857210364637,-7330739156377739483,4711670716640376464,3315142407059383314,569286942632052879,
  -1554494242981308297,1897999854932114769,-3551118359116872780,-3785425734406749421,-2835399305386018931,
  -2073166519428774482,-5266374835859225033,11701968915743190,-905216614479153624)
order by p.total_exec_time desc;
