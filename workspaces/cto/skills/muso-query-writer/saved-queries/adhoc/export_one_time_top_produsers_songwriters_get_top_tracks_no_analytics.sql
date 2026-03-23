/*
id: export_one_time_top_produsers_songwriters_get_top_tracks_no_analytics
title: [adhoc] Export one-time top produsers-songwriters get top tracks no analytics
athena_id: 9db1d124-d1e4-449c-a946-fcda5f118937
primary_tag: adhoc
tags: [adhoc]
athena_database: sandbox-oleg
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

drop TABLE `platform-data-merging-catalog-prod`.adhoc_CU_86953w9yf

select count(1) from "platform-data-merging-catalog-prod"."adhoc_CU_86953w9yf"

select * from "platform-data-merging-catalog-prod"."adhoc_CU_86953w9yf" limit 10

CREATE TABLE "platform-data-merging-catalog-prod"."adhoc_CU_86953w9yf" WITH (
	external_location = 's3://platform-data-processing-lake-prod/merging/catalog/industry_db/analytics/adhoc/CU_86953w9yf/v2/',
	format = 'JSON'
) AS with pf as (
	select profile_id
	from (
			select profile_id,
				min(position) as position,
				max(score) as score
			from "platform-industry-calc-prod".calc_credit_score_charts_entries_history
			where date = cast(
					date_add('day', -4, date_trunc('week', current_date)) as varchar
				)
				and category in ('Producer', 'Songwriter')
			group by 1
		)
	order by score desc,
		position asc
	limit 150000
), p as (
	select _id as profile_id,
		name,
		country,
		common_credits,
		popularity
	from "platform-industry-bi-prod".matvw_catalog_profile
		join pf ON (profile_id = _id)
	where not is_deleted
),
pt as (
	select p.profile_id,
		t._id as track_id,
		arbitrary(default_raw_recording_id) as default_raw_recording_id,
		max(t.popularity) as track_popularity,
		BOOL_OR(
			cardinality(
				filter(
					tp.catalog_credits,
					c->lower(c.parent) like '%producer%'
				)
			) > 0
		) as is_producer,
		bool_or(
			cardinality(
				filter(
					tp.catalog_credits,
					c->lower(c.parent) like '%songwriter%'
				)
			) > 0
		) as is_songwriter,
		min(date(from_unixtime(release_timestamp / 1000))) as release_date,
		arbitrary(name) as name,
		arbitrary(country) as country,
		arbitrary(common_credits) as common_credits,
		arbitrary(p.popularity) as popularity,
		max(streams) as streams
	from "platform-industry-bi-prod".matvw_catalog_track as t
		cross join unnest(profiles) as tpc(tp)
		join p ON(tp.profile_id = p.profile_id)
		left join "platform-data-merging-catalog-prod"."industry_data_processing_analytics_maintenance_track_final_stats" as ts ON (ts.track_id = t._id)
	where not is_deleted
	group by 1,
		2
),
t as (
	select distinct default_raw_recording_id as _id
	from (
			select profile_id,
				track_id,
				row_number() over (
					partition by profile_id
					order by track_popularity desc,
						release_date desc
				) as track_rank,
				streams,
				default_raw_recording_id
			from pt
		)
	where streams is null
		and track_rank <= 10
),
a as (
	select distinct try(release_ids [ 1 ]) as raw_release_id
	from t
		join "platform-industry-bi-prod".matvw_raw_recording USING (_id)
)
select 'create' AS action,
	'spotify' as source,
	'album' as entity_type,
	split_part(raw_release_id, ':', 2) as entity_id,
	'adhoc-3p-export-CU-86953w9yf' AS origin,
	1 as priority,
	1 as version
from a
where raw_release_id like 'spotify:%'
-- limit 100