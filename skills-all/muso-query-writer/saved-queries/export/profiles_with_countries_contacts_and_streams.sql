/*
id: profiles_with_countries_contacts_and_streams
title: [export] Profiles with countries, contacts and streams
athena_id: 36c71686-a610-4731-a76b-9dee8093bd8f
primary_tag: export
tags: [export]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with pf as (
	select profile_id
	from (
			select profile_id,
				min_by(category, position) as category,
				min(position) as position,
				max(score) as score
			from "platform-industry-calc-prod".calc_credit_score_charts_entries_history
			where date = cast(
					date_add('day', -4, date_trunc('week', current_date)) as varchar
				)
				and category in ('Producer', 'Songwriter')
			group by 1
		)
		where score > 0
), p as (
	select _id as profile_id,
		name,
		country,
		common_credits,
		popularity
	from hive.default.matvw_catalog_profile
		join pf ON (profile_id = _id)
	where not is_deleted
),
pt as (
	select p.profile_id,
		t._id as track_id,
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
	from hive.default.matvw_catalog_track as t
		cross join unnest(profiles) as tpc(tp)
		join p ON(tp.profile_id = p.profile_id)
		left join postgresql_industry.public."industry_data_processing_analytics_maintenance_track_final_stats" as ts ON (ts.track_id = t._id)
	where not is_deleted
	group by 1,
		2
),
ip as (
	select _id as profile_id,
		MIN(IF(c.type = 'facebook', c.value)) as fb,
		MIN(IF(c.type = 'twitter', c.value)) as x,
		MIN(IF(c.type = 'instagram', c.value)) as ig,
		MIN(IF(c.type = 'website', c.value)) as web,
		MIN(IF(c.type = 'youtube', c.value)) as yt
	from "platform-industry-db-industry-prod".catalog_profile
		cross join unnest(contacts) as pc(c)
	group by 1
)
select arbitrary(name) as name,
	arbitrary(country) as country,
-- 	arbitrary(popularity) as popularity,
	array_join(
		transform(
			arbitrary(common_credits),
			c->if(lower(c) like '%producer%', 'Producer', c)
		),
		','
	) as common_credits,
	count(1) as total_credit_count,
	count_if(is_songwriter) as songwriting_credit_count,
	count_if(is_producer) as producer_credit_count,
	SUM(streams) as total_streams,
	SUM(IF(is_songwriter, streams, 0)) as songwriting_streams,
	SUM(IF(is_producer, streams, 0)) as producer_streams,
	MIN(release_date) as year_first_release,
	ARBITRARY(ig) as IG_url,
	ARBITRARY(fb) as FB_url,
	ARBITRARY(yt) as YT_url,
	ARBITRARY(x) as X_url,
	ARBITRARY(web) as Website,
	'https://credits.muso.ai/profile/' || profile_id as muso_url
from pt
	left join ip using(profile_id)
group by profile_id
having count_if(is_songwriter) > 0
	or count_if(is_producer) > 0
order by songwriting_streams + producer_streams desc 
-- offset 150000
limit 150000