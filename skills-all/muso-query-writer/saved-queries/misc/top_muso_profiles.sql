/*
id: top_muso_profiles
title: TOP Muso Profiles
athena_id: f3d40829-324b-4f42-94c2-59b872737ac5
primary_tag: misc
tags: [misc]
athena_database: neptune-nodes-json-production
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro_users AS (
	select s.seatid AS profile_id,
		TRUE AS in_muso,
		BOOL_OR(
			lower("subscriptionstatus") IN ('pro', 'trial', 'suspended', 'pending')
			AND s.status = 'active'
		) AS is_muso_active
	from "production-musomvp"."public_users" AS u
		join "production-musomvp"."public_discovery_seats" AS s ON(u.id = s.userid)
	where s.seatid is not null
	group by 1
),
_track AS (
	select "~id" AS track_id,
		COALESCE(popularity, 1) AS popularity,
		percent_rank() OVER (
			order by popularity
		) AS popularity_rank
	from "neptune-nodes-json-production"."track"
),
_profile AS (
	select "~id" AS profile_id,
		name
	from "neptune-nodes-json-production"."professional"
),
profile_tracks AS (
	select profile_id,
		name,
		percent_rank() OVER (
			order by tracks_popularity
		) AS popularity_rank,
		percent_rank() OVER (
			order by producer_tracks_popularity
		) AS producer_popularity_rank,
		percent_rank() OVER (
			order by engineer_tracks_popularity
		) AS engineer_popularity_rank,
		percent_rank() OVER (
			order by songwriter_tracks_popularity
		) AS songwriter_popularity_rank
	from (
			select profile_id,
				ARBITRARY(name) AS name,
				SUM(track_popularity) AS tracks_popularity,
				SUM(producer_track_popularity) AS producer_tracks_popularity,
				SUM(engineer_track_popularity) AS engineer_tracks_popularity,
				SUM(songwriter_track_popularity) AS songwriter_tracks_popularity
			from (
					select "~from" AS profile_id,
						track_id,
						MAX(_track.popularity) AS track_popularity,
						row_number() OVER(
							PARTITION BY "~from"
							order by MAX(_track.popularity) desc
						) AS profile_track_rank,
						MAX(
							IF(
								lower(parent) LIKE '%producer%'
								or lower(child) like '%producer%',
								_track.popularity,
								0
							)
						) AS producer_track_popularity,
						MAX(
							IF(
								lower(parent) LIKE '%engineer%',
								_track.popularity,
								0
							)
						) AS engineer_track_popularity,
						MAX(
							IF(
								lower(parent) LIKE '%writer%',
								_track.popularity,
								0
							)
						) AS songwriter_track_popularity,
						MAX(
							IF(
								lower(parent) LIKE '%organi_ation%',
								_track.popularity,
								0
							)
						) AS organization_track_popularity
					from "neptune-edges-json-production"."collaborateover"
						JOIN _track ON("~to" = track_id)
					GROUP BY 1,
						2
				)
				join _profile USING(profile_id)
			where organization_track_popularity = 0
				and profile_track_rank <= 1000
			group by 1
		)
)
select profile_id,
	name,
	COALESCE(in_muso, FALSE) AS in_muso,
	COALESCE(is_muso_active, FALSE) AS is_muso_active,
	popularity_rank,
	engineer_popularity_rank,
	producer_popularity_rank,
	songwriter_popularity_rank
from profile_tracks
	left join pro_users USING(profile_id)
order by popularity_rank desc
limit 10000