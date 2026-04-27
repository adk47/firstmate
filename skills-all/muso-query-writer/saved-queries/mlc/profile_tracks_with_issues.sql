/*
id: profile_tracks_with_issues
title: [MLC] Profile tracks with issues
athena_id: 6b0c6501-dd18-4635-8f60-f81065ee9263
primary_tag: mlc
tags: [mlc]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with mlc_w as (
	select feedprovidersworkid,
	    arbitrary(iswc) as iswc,
		BOOL_OR(lower(partyrole) like '%publisher%') as has_publisher,
		SUM(rightsharepercentage) as total_work_share_pct
	from hive."platform-industry-mlc-bi-prod".works
		left join hive."platform-industry-mlc-bi-prod".workrightshares USING(feedprovidersworkid)
	group by 1
),
mlc as (
	select UPPER(isrc) as isrc,
		true as in_mlc,
		BOOL_OR(has_publisher) as has_publisher,
		BOOL_OR(feedprovidersworkid is not null) as has_work,
		GREATEST(100.0 - MAX(total_work_share_pct), 0.0) as missing_shares_pct,
		array_agg(distinct iswc) as iswcs
	from mlc_w
		join hive."platform-industry-mlc-bi-prod".worksrecordings as wr USING(feedprovidersworkid)
		right join hive."platform-industry-mlc-bi-prod".recordings as r USING(feedprovidersrecordingid)
	group by 1
),
t as (
	select _id as track_id,
		array_agg(upper(replace(i.isrc, '-', ''))) as isrcs,
		min(title) as title,
		min_by(
			array_join(transform(artists, a->a.name), ', '),
			title
		) as artists,
		coalesce(BOOL_OR(in_mlc), false) as in_mlc,
		coalesce(BOOL_OR(has_publisher), false) as has_publisher,
		coalesce(BOOL_OR(has_work), false) as has_work,
		COALESCE(MIN(missing_shares_pct), 0) as missing_shares_pct,
		array_distinct(flatten(array_agg(iswcs))) as iswcs
	from hive."platform-industry-bi-prod".matvw_catalog_track
		cross join unnest(isrcs) as i(isrc)
		left join mlc ON(upper(replace(i.isrc, '-', '')) = mlc.isrc)
	where not is_deleted -- 	filter by profile 
		and cardinality(
			filter(
				profiles,
				p->p.profile_id = '7486283c-cae3-4d25-b9aa-ab570247e2a9'
				and cardinality(
					filter(p.catalog_credits, pc->pc.parent = 'Songwriter')
				) > 0
			)
		) > 0
	group by 1
)
select track_id,
	arbitrary(in_mlc) as in_mlc,
	arbitrary(has_work) as has_work,
	arbitrary(has_publisher) as has_publisher,
	arbitrary(missing_shares_pct) as missing_shares_pct,
	max(ce_streams) as streams,
	arbitrary(title) as title,
	arbitrary(artists) as artists,
	array_join(arbitrary(iswcs), ',') as iswcs,
	array_join(arbitrary(isrcs), ',') as isrcs
from t
	left join "platform-industry-calc-prod".calc_analytics_cube_track_history USING(track_id)
where date = '2024-07-30'
	and period = 'all'
	and (
		not in_mlc
		or not has_work
		or not has_publisher
		or missing_shares_pct > 0
	)
group by 1
order by streams desc
limit 10000