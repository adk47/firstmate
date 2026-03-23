/*
id: total_numbers
title: [inhouse_analytics] Total numbers
athena_id: 66ed8071-d880-4ec1-92d9-d9f9e1522ae1
primary_tag: inhouse_analytics
tags: [inhouse_analytics]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p AS (
	select distinct seatid AS profile_id
	from "platform-core-backend-export-prod".public_roster_seats
	where status = 'active'
)
select count(1) AS num_daily_track_stats,
	count(distinct track_id) AS num_tracks,
	count(distinct c.profile_id) AS num_profiles,
	count(distinct profile_id) AS num_pro_profiles,
	count(distinct IF(profile_id is not null, track_id)) AS num_pro_tracks
from "platform-industry-db-industry-prod".analytics_track_daily
	cross join unnest(profile_credits) AS pc(c)
	left join p ON (profile_id = c.profile_id)