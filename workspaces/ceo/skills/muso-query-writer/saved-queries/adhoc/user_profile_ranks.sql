/*
id: user_profile_ranks
title: [AdHoc] User profile ranks
athena_id: eaf5e92c-2acb-4489-8caf-6bbcabb5595c
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with uc as (
	select distinct u.id as user_id,
		c.profileid as profile_id
	from "platform-core-backend-export-prod".public_users as u
		join "platform-core-backend-export-prod".public_claiming as c ON (c.teamid = u.defaultteamid)
	where c.status = 'processed'
),
us as (
	select distinct u.id as user_id,
		s.seatid as profile_id
	from "platform-core-backend-export-prod".public_users as u
		join "platform-core-backend-export-prod".public_roster_seats as s ON (s.teamid = u.defaultteamid)
		left join (
			select distinct user_id
			from uc
		) as nu ON (u.id = nu.user_id)
	where nu.user_id is null
),
p as (
	select _id as profile_id,
		COALESCE(rank, 5) as rank
	from "platform-industry-bi-prod".matvw_catalog_profile
	where not is_deleted
),
u as (
	select u.id as user_id,
		BOOL_OR(coalesce(s.status = 'active', false)) as is_paid
	from "platform-core-backend-export-prod".public_subscriptions as s
		right join "platform-core-backend-export-prod".public_users as u ON (s.teamid = u.defaultteamid)
	group by 1
)
select COALESCE(cast(user_rank as varchar), 'N/A') as user_rank,
	count(1) as num_users,
	count_if(is_claimed) as num_claimed,
	count_if(is_paid) as num_paid,
	count_if(is_paid and is_claimed) as num_claimed_paid
from (
		select profile_id,
			min(rank) as user_rank,
			BOOL_OR(is_paid) as is_paid,
			bool_or(is_claimed) as is_claimed
		from (
				select user_id,
					profile_id,
					true as is_claimed
				from uc
				union
				select user_id,
					profile_id,
					false as is_claimed
				from us
			) as uu
			join p USING(profile_id)
			join u USING(user_id)
		group by 1
	) as up
group by 1
