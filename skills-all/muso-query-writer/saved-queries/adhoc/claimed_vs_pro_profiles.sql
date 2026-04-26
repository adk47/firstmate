/*
id: claimed_vs_pro_profiles
title: [adhoc] Claimed vs PRO profiles
athena_id: fcde3f8b-edae-4741-b7bd-c1af9bb60535
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with c AS (
	select profileid,
		teamid,
		true as is_claimed
	from "production-musomvp".public_claiming
	where status = 'processed'
),
s AS (
	select seatid as profileid,
		teamid,
		true as is_pro
	from "production-musomvp".public_roster_seats
	where status = 'active'
)
select coalesce(is_pro, FALSE) AS is_pro,
	coalesce(is_claimed, FALSE) AS is_claimed,
	count(1)
from s
	full join c using(profileid, teamid)
group by 1,
	2
order by 3 desc