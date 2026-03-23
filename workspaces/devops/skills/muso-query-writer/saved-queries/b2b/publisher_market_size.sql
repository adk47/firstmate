/*
id: publisher_market_size
title: [B2B] Publisher market size
athena_id: a01a4c3f-d847-4ae9-b3be-21e39d68822f
primary_tag: b2b
tags: [b2b]
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
),
pc as (
select feedproviderspartyid,
	count(distinct iswc) as num_works,
	count(distinct isrc) as num_isrcs
from "platform-industry-mlc-bi-prod".workrightshares
	join "platform-industry-mlc-bi-prod".parties USING (feedproviderspartyid)
	left join "platform-industry-mlc-bi-prod".works USING(feedprovidersworkid)
	left join "platform-industry-mlc-bi-prod".worksrecordings USING(feedprovidersworkid)
	left join "platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
where lower(partyrole) like '%publisher%'
group by 1
)

select 
    count(1) as num,
    count_if(num_isrcs>0) as num_0,
    count_if(num_isrcs>100) as num_100,
    count_if(num_isrcs>1000) as num_1000,
    count_if(num_isrcs>10000) as num_10000
from pc