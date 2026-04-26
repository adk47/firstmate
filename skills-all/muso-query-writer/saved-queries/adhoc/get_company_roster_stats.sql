/*
id: get_company_roster_stats
title: [AdHoc] Get company roster stats
athena_id: 7f0c3ecd-865e-4a99-a5fb-927a1d8298fb
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with m as (
	select distinct profile_id as company_id,
		member_id as profile_id,
		membership_type
	from hive.default.matvw_catalog_member
	where not is_deleted
		and membership_type in ('record_label', 'manager', 'publisher')
		and profile_id in (
			'92882d52-955d-4410-9ad9-cdde08b39a76',
			'03473407-e366-4b97-9dd3-acf13a570b98',
			'8ae5320c-7ae4-48a2-902b-8b402629415f',
			'4d702235-8621-4784-a409-5bc61806bd99'
		)
),
c as (
	select company_id,
		m.profile_id,
		t._id as track_id,
		date_diff(
			'day',
			from_unixtime(release_timestamp / 1000),
			current_date
		) < 366 as is_new
	from hive.default.matvw_catalog_track as t
		cross join unnest(profiles) as tp(p)
		join m ON (m.profile_id = p.profile_id)
	where not is_deleted
),
cc as (
	select company_id,
		count(distinct track_id) as num_company_credits,
		count(distinct IF(is_new, track_id)) as num_company_credits_1y
	from c
	group by 1
),
pc as (
	select profile_id,
		count(distinct track_id) as num_profile_credits,
		count(distinct IF(is_new, track_id)) as num_profile_credits_1y
	from c
	group by 1
),
p as (
	select _id as profile_id,
		name,
		array_join(common_credits, ',') as common_credits
	from hive.default.matvw_catalog_profile
	where not is_deleted
),
ts as (
	select track_id,
		MAX_BY(streams, date) as streams,
		MAX_BY(shazams, date) as shazams,
		MAX_BY(views, date) as views,
		MAX_BY(videos, date) as videos
	from "platform-stats-export-prod".public_track_daily
	group by 1
),
ps as (
	select profile_id,
		SUM(streams) as profile_streams
	from "platform-stats-export-prod".public_profile_track as pt
		join (
			select distinct profile_id
			from m
		) as p USING(profile_id)
		join ts USING(track_id)
	group by 1
),
cs as (
	select company_id,
		SUM(streams) as streams,
		SUM(shazams) as shazams,
		SUM(views) as views,
		SUM(videos) as videos
	from (
			select company_id,
				track_id,
				MAX(streams) as streams,
				MAX(shazams) as shazams,
				MAX(views) as views,
				MAX(videos) as videos
			from "platform-stats-export-prod".public_profile_track as pt
				join m USING(profile_id)
				join ts USING(track_id)
			group by 1,
				2
		)
	group by 1
)
select *,
	streams / num_profiles as avg_streams
from (
		select *
		from (
				select company_id,
					c.name as company,
					count(1) over (partition by company_id) as num_profiles,
					streams,
					shazams,
					views,
					videos,
					p.profile_id,
					p.name as profile,
					p.common_credits as profile_common_credits,
					profile_streams,
					row_number() over (
						partition by company_id
						order by profile_streams desc
					) as profile_rank
				from m
					join p as c ON(c.profile_id = company_id)
					join p ON(p.profile_id = m.profile_id)
					join cs USING (company_id)
					join ps ON (ps.profile_id = m.profile_id)
			)
		where profile_rank < 6
	)
	join cc USING(company_id)
	join pc USING(profile_id)
order by company,
	profile_rank