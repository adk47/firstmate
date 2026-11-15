-- per-database size and cumulative counters since stats_reset (pg_stat_database), n17 primary
select now() as measured_at, pg_postmaster_start_time() as postmaster_start;
select extname, extversion from pg_extension where extname='pg_stat_statements';
select dealloc, stats_reset from pg_stat_statements_info;
select count(*) as pgss_entries, min(stats_since) as oldest_entry, max(stats_since) newest_entry from pg_stat_statements;
select d.datname, pg_size_pretty(pg_database_size(d.datname)) sz, pg_database_size(d.datname) bytes, s.numbackends nb, s.xact_commit, s.tup_returned, s.tup_fetched, s.tup_inserted, s.tup_updated, s.tup_deleted, s.blks_read, s.blks_hit, round(s.blk_read_time/1000) blk_read_s, s.temp_bytes, s.stats_reset
from pg_database d join pg_stat_database s on s.datid=d.oid where not d.datistemplate order by pg_database_size(d.datname) desc;
