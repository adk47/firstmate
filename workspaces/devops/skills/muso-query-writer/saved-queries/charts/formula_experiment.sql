/*
id: formula_experiment
title: [Charts] Formula experiment
athena_id: 321db8b6-4699-4d01-a746-79cc9c90751e
primary_tag: charts
tags: [charts]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with pt AS (
	select distinct profile_id,
		master_track_id AS _id
	from "matvw_catalog_master_credit" AS c
		cross join unnest("credits_parent") AS cc(parent)
	where parent like 'Producer%'
		and not is_deleted
),
ts AS (
	select profile_id AS _id,
		_id AS track_id,
		case
			when popularity >= 80 then (popularity -80) * 32 + 460
			when popularity >= 60 then (popularity -60) * 16 + 140
			when popularity >= 40 then (popularity -40) * 4 + 60
			when popularity >= 20 then (popularity -20) * 2 + 20
			when popularity > 0 then popularity  else 0
		END AS score,
		ROW_NUMBER() OVER(
			partition by profile_id
			order by popularity desc
		) AS r_n
	from matvw_catalog_track
		join pt USING (_id)
	where not is_deleted
)
select _id AS profile_id,
	arbitrary(name) AS name,
	SUM(score) AS credit_score,
	count(1) AS num_tracks
from "matvw_catalog_profile"
	join ts USING(_id)
where r_n <= 1000
group by 1
order by 3 desc
limit 100