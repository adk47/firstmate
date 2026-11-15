-- Are ticker-prod and ticker-tier replicas of the SAME replicated tables, or two independent copies?
-- Read from system.replicas on shard 0 replica 0 of each CHI.
SELECT hostName() AS host, table, zookeeper_path, replica_name, total_replicas, active_replicas,
       is_readonly, queue_size, absolute_delay, log_pointer, log_max_index
FROM system.replicas
WHERE database = 'ticker_prod' AND table IN ('rollup_1d_local','rollup_1h_local','rollup_1m_local','raw_events_local','dim_paid_entities','entity_set_snapshots')
ORDER BY table
FORMAT PrettyCompactMonoBlock
