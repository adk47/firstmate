/*
id: amount_of_tracks
title: [SLA] Amount of tracks
athena_id: dc14d775-ffb1-4e23-83c5-b7e94b4cd213
primary_tag: sla
tags: [sla]
athena_database: platform-industry-bi-dev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pro_profiles AS (
	--sql
	select distinct seatid AS profile_id
	FROM "production-musomvp"."public_roster_seats"
	WHERE status = 'active' --endsql
),
prs AS (
	select raw_recording_id AS _id,
		ARBITRARY(pp.profile_id) IS NOT NULL AS is_pro_recording
	from "platform-industry-bi-prod"."matvw_catalog_profile" AS p
		JOIN pro_profiles AS pp ON (p._id = pp.profile_id)
		JOIN "platform-industry-bi-prod"."matvw_catalog_master_credit" AS c ON (p._id = c.profile_id)
		JOIN "platform-industry-bi-prod"."matvw_catalog_track" AS t ON (c.master_track_id = t._id)
		cross join unnest(raw_recording_ids) AS tr(raw_recording_id)
	where not coalesce(p.is_deleted, FALSE)
		and p.profile_type in ('professional', 'artist', 'organization')
		and not coalesce(c.is_deleted, FALSE)
		and not coalesce(t.is_deleted, FALSE)
		and raw_recording_id like 'spotify:%'
	GROUP BY 1
)
SELECT count_if(
		-- 2 times minimum
		date_diff('day', release_date, current_date) < 30
		and random(15) <= sqrt(popularity) + IF(is_pro_recording, 1, 0)
	),
	count_if(
		-- 2 times
		date_diff('day', release_date, current_date) between 31 and 90
		and random(30) <= sqrt(popularity) + IF(is_pro_recording, 1, 0)
	),
	count_if(
		-- 1 time
		date_diff('day', release_date, current_date) between 91 and 360
		and random(270) <= sqrt(popularity) + IF(is_pro_recording, 1, 0)
	),
	count_if(
		-- 1 time a year for the ones with popularity or pro users
		date_diff('day', release_date, current_date) > 360
		and random(360) = 0
		and (
			popularity > 0
			or is_pro_recording
		)
	),
	count_if(
		-- 1 time per 6 years for all the rest
		date_diff('day', release_date, current_date) > 360
		and random(2000) = 0
		and popularity = 0
		and not is_pro_recording
	),
	count(1)
from (
		select _id,
			COALESCE(
				try(
					date(
						case
							when LENGTH(release_date) >= 10 THEN SUBSTR(release_date, 1, 10)
							when LENGTH(release_date) >= 7 THEN SUBSTR(release_date, 1, 7) || '-01'
							when LENGTH(release_date) >= 4 THEN SUBSTR(release_date, 1, 4) || '-01-01' else NULL
						end
					)
				),
				DATE('2000-01-01')
			) AS release_date,
			COALESCE(custom_data.popularity, 0) AS popularity,
			COALESCE(
				DATE(
					from_unixtime(updated_timestamp / 1000)
				),
				DATE('2023-04-01')
			) AS updated_date,
			COALESCE(is_pro_recording, FALSE) AS is_pro_recording
		FROM "platform-industry-bi-prod"."matvw_raw_recording"
			LEFT JOIN prs USING(_id)
		WHERE source = 'spotify'
	)
WHERE date_diff('day', release_date, updated_date) > 2