-- pg_stat_user_tables for the current database: families (trailing _<digits> generation suffix folded), reads, writes, size.
-- Counters are cumulative since the table's creation or the last stats reset (pg_stat_database.stats_reset is NULL on this host).
with t as (
  select regexp_replace(relname, '_[0-9]+$', '_N') fam, relid, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
         n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, pg_total_relation_size(relid) sz,
         greatest(last_seq_scan, last_idx_scan) last_read
  from pg_stat_user_tables)
select current_database() db, fam, count(*) rels, pg_size_pretty(sum(sz)) size, sum(sz) size_bytes, sum(n_live_tup) live_rows,
       sum(seq_scan) seq_scans, sum(seq_tup_read) seq_tup_read, sum(idx_scan) idx_scans, sum(idx_tup_fetch) idx_tup_fetch,
       sum(n_tup_ins) ins, sum(n_tup_upd) upd, sum(n_tup_del) del, max(last_read)::timestamp(0) last_read
from t group by fam order by sum(sz) desc limit 30;
