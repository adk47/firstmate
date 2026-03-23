/*
id: artist_member_profiles_impact
title: [adhoc] Artist Member profiles impact
athena_id: 168400e2-b5ab-42b9-a37f-dee2dc66417c
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with m AS (
	select member_id as seatid,
		profile_id as member_of_id,
		name as member_of_name,
		p.credits_count
	from "platform-industry-db-industry-prod".catalog_member
		join "platform-industry-bi-prod".matvw_catalog_profile as p ON (profile_id = p._id)
	where not coalesce(deleted.is_deleted, FALSE)
		and not is_deleted
),
p as (
	select seatid as profileid,
		arbitrary(name) AS profile_name,
		count(distinct member_of_id) AS num_members,
		max_by(member_of_id, m.credits_count) AS main_member_id,
		max_by(member_of_name, m.credits_count) AS main_member_name
	from "production-musomvp".public_roster_seats AS s
		join "platform-industry-bi-prod".matvw_catalog_profile as p ON (seatid = p._id)
		left join m USING(seatid)
	where s.status = 'active'
		and not p.is_deleted
	group by 1
),
ts AS (
	select track_id AS master_track_id,
		MAX(streams) AS streams
	from (
			select profileid AS profile_id,
				trackid as track_id,
				SUM(
					COALESCE(spotifystreams, 0) + COALESCE(soundcloudstreams, 0) + COALESCE(youtubeviews, 0)
				) AS streams
			from "production-musomvp"."public_profile_track_stats"
				join p using(profileid)
			group by 1,
				2
		)
	group by 1
)
select *,
	if(
		main_member_name is null,
		1.0,
		1.0 * levenshtein_distance(lower(profile_name), lower(main_member_name)) / length(profile_name)
	) AS names_diff,
	1.0 * affected_streams / total_streams AS affected_streams_pct
from (
		select profile_id,
			arbitrary(profile_name) AS profile_name,
			count(1) AS tracks,
			count_if(affected_streams > 0) AS affected_tracks,
			SUM(streams) AS total_streams,
			SUM(affected_streams) AS affected_streams,
			arbitrary(main_member_id) AS main_member_id,
			arbitrary(main_member_name) AS main_member_name
		from (
				select profile_id,
					master_track_id as track_id,
					streams,
					IF(
						cardinality(
							filter(catalog_credits, c->c.child = 'Artist Member')
						) > 0
						and cardinality(
							filter(catalog_credits, c->c.child <> 'Artist Member')
						) = 0,
						streams,
						0
					) AS affected_streams
				from "platform-industry-bi-prod".matvw_catalog_master_credit
					join ts USING(master_track_id)
			)
			join p ON (profileid = profile_id)
		group by 1
	)
where affected_tracks > 0
order by 1.0 * affected_streams / total_streams desc