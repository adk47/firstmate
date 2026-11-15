-- The olap statements carrying the most WAL, with text (truncated to 500 chars; normalized by
-- pg_stat_statements, so no literals). Shows that SELECT COUNT(*) on the track cube carries WAL.
select p.queryid, p.calls, p.rows, pg_size_pretty(p.wal_bytes) wal, p.stats_since::date since,
       left(regexp_replace(p.query, '\s+', ' ', 'g'), 500) q
from pg_stat_statements p join pg_database d on d.oid = p.dbid
where d.datname = 'olap' and p.wal_bytes > 20e9
order by p.wal_bytes desc limit 12;
