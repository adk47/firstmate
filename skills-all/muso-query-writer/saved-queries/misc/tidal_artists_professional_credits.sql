/*
id: tidal_artists_professional_credits
title: [research] Tidal Artists professional credits
athena_id: c6969dbe-8330-46af-ad8a-397611cb893f
primary_tag: research
tags: [research]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select round(100 * num_prof_credits / num_credits) AS "% of professional credits",
	count(1) AS "# raw profiles not synced",
	sum(num_recordings) AS num_recordings,
	arbitrary(
		'https://listen.tidal.com/artist/' || substr(profile_id, 7)
	) AS tidal_url
from (
		select rp._id AS profile_id,
			count(1) AS num_credits,
			count_if(rrc.credit not like '%artist%') AS num_prof_credits,
			count(
				distinct if(rrc.credit not like '%artist%', recording_id)
			) AS num_recordings
		from hive."platform-industry-bi-prod"."matvw_catalog_profile" AS cp
			cross join unnest(raw_profile_ids) AS rp(rpid)
			right join hive."platform-industry-bi-prod"."matvw_raw_profile" AS rp ON (rpid = rp._id)
			join "platform-industry-db-industry-prod"."raw_recording_credit" AS rrc ON (rp._id = rrc.profile_id)
		where rp."profile_type" = 'artist'
			and rp.source = 'tidal'
			and cp._id is null
		group by 1
	)
where num_credits > 4
group by 1
order by 1 desc