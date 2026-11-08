/*
id: b2b_mlc_import
title: [HubSpot][B2B] MLC Import
athena_id: e9ce76b4-f4a3-4b82-a1a9-b9ea418285cf
primary_tag: hubspot
tags: [hubspot]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with mp as (
	select 'mlc:' || cast(feedproviderspartyid as varchar) as rpid,
		*
	from hive."platform-industry-mlc-bi-prod".parties
)
select name,
	credits_count,
	popularity,
	muso_url,
	concat(
		'<strong>MLC data</strong>',
		'<br>',
		array_join(note_lines, '')
	) as note
from (
		select 'https://muso.ai/profile/' || _id as muso_url,
			arbitrary(name) as name,
			max(credits_count) as credits_count,
			max(popularity) as popularity,
			array [ COALESCE(
				'fullname: ' || arbitrary(fullname) || '<br>',
				''
			),
			COALESCE(
				'namesbeforekeyname: ' || arbitrary(namesbeforekeyname) || '<br>',
				''
			),
			COALESCE('keyname: ' || arbitrary(keyname) || '<br>', ''),
			COALESCE(
				'namesafterkeyname: ' || arbitrary(namesafterkeyname) || '<br>',
				''
			),
			COALESCE(
				'contactname: ' || arbitrary(contactname) || '<br>',
				''
			),
			COALESCE(
				'contactemail: ' || arbitrary(contactemail) || '<br>',
				''
			),
			COALESCE(
				'contactphone: ' || arbitrary(cast(contactphone as varchar)) || '<br>',
				''
			),
			COALESCE(
				'contactaddress: ' || arbitrary(contactaddress) || '<br>',
				''
			) ] as note_lines
		from hive."platform-industry-bi-prod".matvw_catalog_profile as p
			cross join unnest(raw_profile_ids) as r(rpid)
			join mp USING(rpid)
		where not is_deleted
		group by _id
	)
where credits_count > 0