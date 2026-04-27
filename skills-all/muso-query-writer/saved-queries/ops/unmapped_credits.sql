/*
id: unmapped_credits
title: [ops] Unmapped credits
athena_id: 92af35f2-b0c2-4acf-a550-a05ce9f57ee7
primary_tag: ops
tags: [ops]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select credit,
	count(1) AS count,
	count_if(recording_id like 'tidal%') AS count_tidal,
	count_if(recording_id like 'jaxsta%') AS count_jaxsta,
	count_if(recording_id like 'genius%') AS count_genius
from hive."platform-industry-bi-prod"."matvw_raw_recording_credit"
where lower(credit) not in (
		select distinct lower(credit)
		from "platform-industry-db-industry-prod"."dict_credit"
			cross join unnest(originals) AS o(credit)
	)
group by 1
order by 2 desc