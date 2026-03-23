/*
id: users_channels_learned_about_muso_from
title: [adhoc] Users channels learned about muso from
athena_id: 4d6742ed-244e-4326-a037-f5163bf3eb3c
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    -- role,
    channel,
	sum(num_users) as num_users
from (
		select json_extract_scalar(onboarding, '$.marketingChannel') as channel,
			json_extract_scalar(onboarding, '$.role') as role,
			count(1) AS num_users
		from "platform-core-backend-export-prod".public_users
		group by 1,
			2
	)
where nullif(channel, '') is not null
group by 1
order by 2 desc