/*
id: pending_sources_last_error_msg
title: Pending Sources - Last error msg
athena_id: 6a71c46c-0512-4ff8-9406-a8cc95231f0c
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with main AS (
	select DATE(substr(createdat, 1, 10)) AS created_date,
		trackid AS track_id,
		spotifyid AS spotify_id,
		source,
		url AS source_url,
		userid AS user_id,
		lastresponsemessage AS last_error_msg
	from "production-musomvp"."public_pending_sources"
	where ispending
		and not COALESCE(isremoved, FALSE)
)
select last_error_msg,
	count(1) AS num
from main
group by 1
order by 2 desc