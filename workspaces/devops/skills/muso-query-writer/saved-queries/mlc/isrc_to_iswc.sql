/*
id: isrc_to_iswc
title: [mlc] Isrc to iswc
athena_id: 4123af25-6898-42de-b9ed-a554443def00
primary_tag: mlc
tags: [mlc]
athena_database: platform-industry-mlc-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with wr as (
	select distinct isrc,
		iswc
	from "platform-industry-mlc-bi-prod".worksrecordings
		join "platform-industry-mlc-bi-prod".works USING(feedprovidersworkid)
		join "platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
	where nullif(isrc, '') is not null
		and nullif(iswc, '') is not null
)
select case
		when popularity > 80 then '80'
		when popularity > 60 then '60'
		when popularity > 40 then '40'
		when popularity > 20 then '20'
		when no_industry_recording then 'N/A' else '0'
	end,
	count_if(no_industry_recording) as num_not_in_muso,
	count(1) as num_isrcs,
	count_if(num_works > 0) AS num_has_works
from (
		select isrc,
			arbitrary(_id) is null AS no_industry_recording,
			min(custom_data.popularity) AS popularity,
			count(distinct iswc) AS num_works
		from wr
			full outer join "platform-industry-bi-prod".matvw_raw_recording USING(isrc)
		group by 1
	)
group by 1
order by 1