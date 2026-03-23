/*
id: get_seats_profile_in
title: [helper] Get seats profile in
athena_id: e9bf8892-32b7-4794-b093-eebb628ff021
primary_tag: helper
tags: [helper]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p as (
	select neptuneprofessionalid as profile_id,
		'neptune' as status,
		email as user_team_id
	from "production-musomvp".public_users
	union all
	select seatid as profile_id,
		status,
		'seat' || teamid as user_team_id
	from "production-musomvp".public_roster_seats
	union all
	select profileid as profile_id,
		status,
		'claiming' || teamid as user_team_id
	from "production-musomvp".public_claiming
)
select *
from p
where profile_id in ('4afb53b5-bb7f-4b82-b8a6-d11c20c9d8cb')

