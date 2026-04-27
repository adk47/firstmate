/*
id: isrcs_in_multiple_releases
title: [AdHoc] ISRCs in multiple releases
athena_id: a20f9278-b5ed-4bf1-8f35-19e3e40cd7d3
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with i as (
	select isrc
	from (
			select array [ 'NLF712305666',
				'NLH2L2400326',
				'GBUR61700339',
				'GBUR61400001',
				'NLF712400129',
				'NLY331505537' ] as isrcs
		)
		cross join unnest(isrcs) as i(isrc)
)
select distinct 
    r.title as track_title,
    re.title as album_title,
    re.custom_data.label,
	i.isrc,
	upc,
	'https://open.spotify.com/album/' || split_part(release_id, ':', 2) as spotify_url
from hive."platform-industry-bi-prod".matvw_raw_recording as r
	join i ON(i.isrc = upper(r.isrc))
	cross join unnest (release_ids) as rl(release_id)
	join hive."platform-industry-bi-prod".matvw_raw_release as re ON (re._id = release_id)
where source = 'spotify'