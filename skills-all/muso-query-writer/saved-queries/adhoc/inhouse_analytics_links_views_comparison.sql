/*
id: inhouse_analytics_links_views_comparison
title: [adhoc] Inhouse analytics links views comparison
athena_id: dd376447-513e-433b-a27f-d2073b5f45f7
primary_tag: adhoc
tags: [adhoc]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with ss AS (
	select trackid as track_id,
		if(
			src.source = 'shorts',
			'youtube',
			src.source
		) || ':' || regexp_replace(src.sourceUrl, '.*/', '') AS _id,
		src.count as views,
		src.sourceUrl as url
	from postgresql_core.public."public_track_activities"
		cross join unnest(
			CAST(
				json_extract(sources, '$') AS ARRAY(
					ROW(
						sourceUrl varchar,
						source varchar,
						user varchar,
						count bigint,
						videoId varchar,
						title varchar,
						recordDate varchar
					)
				)
			)
		) AS s(src)
	where src.source in ('shorts', 'tiktok')
),
ms as (
	select track_id,
		_id,
		views,
		url
	from hive.default.matvw_analytics_video
)
select track_id,
	sum(ms.views) AS views_muso,
	sum(ss.views) AS views_songstats,
	count(ms.views) AS videos_muso,
	count(ss.views) AS videos_songstats,
	arbitrary(ms.url) AS random_muso_url,
	arbitrary(ss.url) AS random_songstats_url
from ss
	full outer join ms USING(track_id, _id)
group by 1
order by coalesce(views_songstats, 0) - coalesce(views_muso, 0) desc
limit 1000