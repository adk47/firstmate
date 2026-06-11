WITH unnested_raw AS (
  SELECT _id AS profile_id, raw_id
  FROM hive."platform-industry-bi-prod".matvw_catalog_profile
  CROSS JOIN UNNEST(raw_profile_ids) AS t(raw_id)
  WHERE is_deleted = false
    AND raw_profile_ids IS NOT NULL
    AND cardinality(raw_profile_ids) > 0
),
unnested_ipi AS (
  SELECT _id AS profile_id, CAST(ipi AS VARCHAR) AS ipi
  FROM hive."platform-industry-bi-prod".matvw_catalog_profile
  CROSS JOIN UNNEST(ipis) AS t(ipi)
  WHERE is_deleted = false
    AND ipis IS NOT NULL
    AND cardinality(ipis) > 0
)
SELECT 'raw_id' AS cluster_kind,
       raw_id AS cluster_key,
       array_join(array_agg(profile_id), ' ') AS profile_ids,
       count(*) AS cluster_size
FROM unnested_raw
GROUP BY raw_id
HAVING count(*) > 1

UNION ALL

SELECT 'ipi', ipi, array_join(array_agg(profile_id), ' '), count(*)
FROM unnested_ipi
GROUP BY ipi
HAVING count(*) > 1

ORDER BY cluster_size DESC
