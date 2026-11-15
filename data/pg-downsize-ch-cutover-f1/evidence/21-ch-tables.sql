SELECT database, name, engine, total_rows, formatReadableSize(total_bytes) AS size, metadata_modification_time
FROM system.tables
WHERE database NOT IN ('system','INFORMATION_SCHEMA','information_schema')
ORDER BY database, total_bytes DESC NULLS LAST, name
FORMAT PrettyCompactMonoBlock
