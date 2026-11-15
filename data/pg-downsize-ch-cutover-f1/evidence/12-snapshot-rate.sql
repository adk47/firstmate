-- Rate snapshot: run twice, the delta between two runs is a measured rate (cumulative counters have no known start).
select now() at time zone 'utc' ts, datname, xact_commit, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
       blks_read, blks_hit, round(blk_read_time) blk_read_ms, temp_bytes,
       case when pg_is_in_recovery() then pg_last_wal_replay_lsn() else pg_current_wal_lsn() end lsn
from pg_stat_database where datname is not null and datname not like 'template%' order by datname;
