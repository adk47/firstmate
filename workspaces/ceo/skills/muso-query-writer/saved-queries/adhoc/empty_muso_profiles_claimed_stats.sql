/*
id: empty_muso_profiles_claimed_stats
title: [adhoc] Empty muso profiles claimed stats
athena_id: fc8cb437-7c70-40eb-89f7-4fb1206d302b
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with mp AS (
	select _id as profile_id
	from "platform-industry-bi-prod".matvw_catalog_profile
	where not is_deleted
		and cardinality(
			filter(raw_profile_ids, pid->pid not like 'muso:%')
		) = 0
),
cl as (
	select profileid AS profile_id,
		name AS team_name,
		email AS team_email,
		status AS claim_status,
		verificationlinks
	from "production-musomvp".public_claiming
		left join "production-musomvp".public_teams as t ON (teamid = t.id)
)
select 
    count(distinct profile_id) AS num_muso_profiles,
    count(distinct IF(master_track_id is null, profile_id)) AS num_no_credits,
    count(distinct IF(master_track_id is null and claim_status = 'processed', profile_id)) AS num_no_credits_but_claimed,
    count(distinct IF(master_track_id is null and claim_status = 'processed' and verificationlinks is null, profile_id)) AS num_no_credits_but_claimed
from mp 
left join cl USING(profile_id)
left join "platform-industry-bi-prod".matvw_catalog_master_credit USING(profile_id)