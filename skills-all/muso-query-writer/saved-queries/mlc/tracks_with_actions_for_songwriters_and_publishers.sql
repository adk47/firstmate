/*
id: tracks_with_actions_for_songwriters_and_publishers
title: [MLC] Tracks with actions for Songwriters and publishers
athena_id: f9e866d2-99fb-40bb-919b-3dc67fc8eae5
primary_tag: mlc
tags: [mlc]
trino_catalog: hive
trino_schema: default
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
	from hive.mlc.works
		left join hive.mlc.workrightshares USING(feedprovidersworkid)
	group by 1
),
mlc as (
	select UPPER(isrc) as isrc,
		true as in_mlc,
		BOOL_OR(has_publisher) as has_publisher,
		array_agg(distinct feedprovidersworkid) as mlc_work_ids,
		BOOL_OR(feedprovidersworkid is not null) as has_work,
		BOOL_OR(iswc is not null) as has_iswc,
		GREATEST(100.0 - MAX(total_work_share_pct), 0.0) as missing_shares_pct,
		array_agg(distinct iswc) as iswcs
	from mlc_w
		join hive.mlc.worksrecordings as wr USING(feedprovidersworkid)
		right join hive.mlc.recordings as r USING(feedprovidersrecordingid)
	group by 1
),
t as (
	select _id as track_id,
		coalesce(max(popularity), 0) as track_popularity,
		array_agg(upper(replace(i.isrc, '-', ''))) as isrcs,
		array_agg(mlc.isrc) as mlc_isrcs,
		min(title) as title,
		min_by(
			array_join(transform(artists, a->a.name), ', '),
			title
		) as artists,
		coalesce(BOOL_OR(in_mlc), false) as in_mlc,
		coalesce(BOOL_OR(has_publisher), false) as has_publisher,
		coalesce(BOOL_OR(has_work), false) as has_work,
		coalesce(BOOL_OR(has_iswc), false) as has_iswc,
		COALESCE(MIN(missing_shares_pct), 0) as missing_shares_pct,
		array_distinct(flatten(array_agg(iswcs))) as iswcs,
		array_distinct(flatten(array_agg(mlc_work_ids))) as mlc_work_ids,
		split_part(
			arbitrary(
				coalesce(
					default_raw_recording_id,
					try(
						filter(raw_recording_ids, r->r like 'spotify:%') [ 1 ]
					)
				)
			),
			':',
			2
		) as spotify_id
	from hive.default.matvw_catalog_track
		cross join unnest(isrcs) as i(isrc)
		left join mlc ON(upper(replace(i.isrc, '-', '')) = mlc.isrc)
	where not is_deleted -- 	filter by profile 
		and cardinality(
			filter(
				profiles,
				p->p.profile_id in ('80bc575e-07ac-49eb-8ec5-bb55946fbd59')
				and cardinality(
					filter(p.catalog_credits, pc->pc.parent = 'Songwriter')
				) > 0
			)
		) > 0
	group by 1
),
a as (
	select track_id,
		MAX_BY(streams, date) as streams
	from "platform-stats-export-prod".public_track_daily
	group by 1
)
select *,
	case
		when nullif(mlc_isrcs, '') is null then 'ISRCs missing'
		when not has_work then 'Unmatched Recordings'
		when nullif(missing_isrcs, '') is not null then 'Some ISRCs missing'
		when nullif(iswcs, '') is null then 'ISWCs missing' else 'No Issues'
	end as action
from (
		select track_id,
			BOOL_OR(coalesce(has_work, false)) as has_work,
			array_join(arbitrary(mlc_work_ids), ',') as mlc_codes,
			array_join(arbitrary(iswcs), ',') as iswcs,
			max(streams) as streams,
			max(track_popularity) as track_popularity,
			arbitrary(title) as title,
			arbitrary(artists) as artists,
			array_join(arbitrary(isrcs), ',') as isrcs,
			array_join(arbitrary(mlc_isrcs), ',') as mlc_isrcs,
			array_join(
				arbitrary(
					array_except(isrcs, coalesce(mlc_isrcs, ARRAY [ ]))
				),
				','
			) as missing_isrcs,
			'https://open.spotify.com/track/' || arbitrary(spotify_id) as spotify_url
		from t
			left join a USING(track_id) -- where
			-- 	not has_work
		group by 1
	)
order by streams desc,
	track_popularity desc