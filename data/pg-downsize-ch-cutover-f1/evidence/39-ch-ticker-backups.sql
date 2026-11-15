-- ClickHouse-native backups on record on this host, by status. The name column is not selected.
SELECT hostName() AS host, status, count() AS n, min(start_time) AS oldest, max(end_time) AS newest,
       formatReadableSize(max(total_size)) AS largest, countIf(name ILIKE 'S3%') AS to_s3
FROM system.backups GROUP BY status ORDER BY n DESC FORMAT PrettyCompactMonoBlock;
