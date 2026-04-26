/*
id: perormance
title: [NFC] Perormance
athena_id: a6c8336a-132a-49ea-ba06-a3214c025797
primary_tag: nfc
tags: [nfc]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with r as (
	select split_part(request_url, '/', 5) as alias,
		count(1) as num_clicks
	from "aws-admin".alb_logs_core_prod_api_v2
	where day between cast(
			date_format(current_date - interval '90' day, '%Y/%m/%d') as varchar
		)
		and cast(
			date_format(current_date - interval '1' day, '%Y/%m/%d') as varchar
		)
		and request_url like 'https://api.muso.ai:443/p/%'
	group by 1
),
p as (
	select alias,
		profileid as profile_id,
		workspaceid as workspace_id,
		userid as user_id
	from postgresql_core.public.public_nfc_card
),
cp as (
	select _id as profile_id,
		name as profile_name,
		popularity
	from hive.default.matvw_catalog_profile
)
select 
	count(distinct profile_id) as num_profiles,
	sum(num_clicks) as num_link_used
from r
	join p USING(alias)
	join cp USING(profile_id)