/*
id: top_songs_without_publishers
title: [MLC] Top songs without publishers
athena_id: cbb04871-a57f-409f-a6d6-80302f11633c
primary_tag: mlc
tags: [mlc]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with mlc as (
	select distinct isrc, true as is_mlc
	from hive."platform-industry-mlc-bi-prod".parties as p
		join hive."platform-industry-mlc-bi-prod".workrightshares as ws USING(feedproviderspartyid)
		join hive."platform-industry-mlc-bi-prod".worksrecordings as wr USING(feedprovidersworkid)
		join hive."platform-industry-mlc-bi-prod".recordings as r USING(feedprovidersrecordingid)
	where lower(ws.partyrole) like '%publisher%'
),
t as (
	select _id as track_id,
		array_agg(isrc) as isrcs,
		min(title) as title,
		min_by(
		    array_join(transform(artists, a->a.name), ', '),
		    title
		) as artists
	from hive."platform-industry-bi-prod".matvw_catalog_track
		cross join unnest(isrcs) as i(isrc)
		left join mlc USING(isrc)
	where not is_deleted
	group by 1
	having count(is_mlc) = 0
)
select track_id,
	max(ce_streams) as streams,
	arbitrary(title) as title,
	arbitrary(artists) as artists,
	arbitrary(isrcs) as isrcs
from t
	join "platform-industry-calc-prod".calc_analytics_cube_track_history USING(track_id)
where date='2024-07-05' and period = 'all'
group by 1
order by 2 desc
limit 10000