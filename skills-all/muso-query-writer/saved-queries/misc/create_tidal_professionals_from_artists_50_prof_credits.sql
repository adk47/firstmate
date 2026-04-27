/*
id: create_tidal_professionals_from_artists_50_prof_credits
title: [sqs] Create tidal professionals from artists >50 prof credits
athena_id: cdf88e43-9bd9-49f0-baeb-0c117e19288a
primary_tag: sqs
tags: [sqs]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 'create_from_raw' AS action_type,
	cast(
		ROW('profile', NULL) AS row(entity_type varchar, entity_id varchar)
	) AS entity,
	cast(
		ROW(ARRAY[profile_id]) AS row(raw_ids array(varchar))
	) AS data
from (
		select rp._id AS profile_id,
			count(1) AS num_credits,
			count_if(rrc.credit not like '%artist%') AS num_prof_credits,
			count(distinct if(rrc.credit not like '%artist%', recording_id)) AS num_recordings
		from hive."platform-industry-bi-prod"."matvw_catalog_profile" AS cp
			cross join unnest(raw_profile_ids) AS rp(rpid)
			right join hive."platform-industry-bi-prod"."matvw_raw_profile" AS rp ON (rpid = rp._id)
			join "platform-industry-db-industry-prod"."raw_recording_credit" AS rrc ON (rp._id = rrc.profile_id)
		where rp."profile_type" = 'artist'
			and rp.source = 'tidal'
			and cp._id is null
		group by 1
	)
where round(100 * num_prof_credits / num_credits) > 50 and num_credits > 10
order by profile_id