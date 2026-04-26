/*
id: top_10k_missing_isrcs_v2
title: [MLC] Top 10K missing ISRCs v2
athena_id: 1769b314-f791-4451-99ed-486c05a7488d
primary_tag: mlc
tags: [mlc]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with mlc as (
	select distinct isrc, true as is_mlc
	from hive.mlc.parties as p
		join hive.mlc.workrightshares as ws USING(feedproviderspartyid)
		join hive.mlc.worksrecordings as wr USING(feedprovidersworkid)
		join hive.mlc.recordings as r USING(feedprovidersrecordingid)
	where lower(ws.partyrole) like '%publisher%'
),
t as (
	select _id as track_id,
		array_agg(i.isrc) as isrcs,
		min(title) as title,
		min_by(
		    array_join(transform(artists, a->a.name), ', '),
		    title
		) as artists
	from hive.default.matvw_catalog_track
		cross join unnest(isrcs) as i(isrc)
		left join mlc ON(
		    UPPER(replace(i.isrc,'-',''))=UPPER(mlc.isrc)
		)
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
where date='2024-07-31' and period = 'all'
group by 1
order by 2 desc
limit 10000