/*
id: publishers_research
title: [B2B] Publishers research
athena_id: ff69f386-1e3d-43e6-ac7a-9150996aae8e
primary_tag: b2b
tags: [b2b]
athena_database: platform-industry-mlc-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select * from parties 
where ipinamenumber = 1070758751
limit 10 -- returns one row for Luzonic
-- feedproviderspartyid 4857948

select * from workidentifiers 
where feedprovidersallocatingpartyid = '4857948' -- returns nothing

select * from worksrecordings 
where feedproviderslinkid = 4857948 -- returns 1 track

select * from recordingidentifiers 
where feedprovidersallocatingpartyid = 4857948
limit 100 -- returns 0 

select * from workrightshares 
where feedproviderspartyid = 4857948
limit 100 -- returns a lot

select * from recordings limit 100

select * from works limit 100

select 
    partyrole, 
    count(1)
from workrightshares 
join parties USING (feedproviderspartyid)
group by 1
order by 2 desc

with wr as (
	select distinct isrc,
		iswc
	from "platform-industry-mlc-bi-prod".worksrecordings
		join "platform-industry-mlc-bi-prod".works USING(feedprovidersworkid)
		join "platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
	where nullif(isrc, '') is not null
		and nullif(iswc, '') is not null
)
select 
    partyrole, 
    count(distinct feedproviderspartyid) as num_parties, 
    count(distinct isrc) as num_isrcs
from workrightshares 
join parties USING (feedproviderspartyid)
join "platform-industry-mlc-bi-prod".worksrecordings USING(feedprovidersworkid)
join "platform-industry-mlc-bi-prod".works USING(feedprovidersworkid)
join "platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
where nullif(isrc, '') is not null
	and nullif(iswc, '') is not null
group by 1
order by 2 desc



select 
    count(1) as num_studios,
    count_if(num_rec > 100) as num_100_recs,
    count_if(num_rec > 1000) as num_1000_recs,
    arbitrary(if(num_rec < 100, studioproducername)) as random,
    arbitrary(if(num_rec > 100, studioproducername)) as random_100
from (
    select 
        studioproducername,
        count(1) as num_rec
    from recordings
    where nullif(studioproducername, '') is not null
    group by 1
)

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