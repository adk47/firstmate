-- Which side runs the refreshable views (who owns the non-replicated dim / nowcast targets)?
SELECT hostName() AS host, view, status, last_success_time, next_refresh_time, exception != '' AS has_exception
FROM system.view_refreshes WHERE database = 'ticker_prod' ORDER BY view
FORMAT PrettyCompactMonoBlock;
-- Engines of the targets the tier computes for itself (not replicas of the old CHI's tables).
SELECT hostName() AS host, name, engine, total_rows FROM system.tables
WHERE database = 'ticker_prod' AND name IN ('dim_paid_entities','nowcast_rate','nowcast_baseline_staging','entity_set_snapshots','profile_box_stats','processed_profile_daily','processed_source_daily')
ORDER BY name FORMAT PrettyCompactMonoBlock;
-- Any ClickHouse-native backup on record on this host?
SELECT count() AS backups_on_record, max(end_time) AS newest FROM system.backups FORMAT PrettyCompactMonoBlock;
