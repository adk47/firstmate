-- n19 identity, recovery state, replay lag, pg_stat_statements window.
select inet_server_addr() addr, pg_is_in_recovery() in_recovery, pg_postmaster_start_time() started,
       now()-pg_last_xact_replay_timestamp() replay_delay,
       (select dealloc from pg_stat_statements_info) dealloc, (select stats_reset from pg_stat_statements_info) pgss_reset,
       (select count(*) from pg_stat_statements) entries, (select min(stats_since) from pg_stat_statements) oldest;
