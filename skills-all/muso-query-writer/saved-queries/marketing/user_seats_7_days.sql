/*
id: user_seats_7_days
title: [marketing] User Seats 7 days
athena_id: d8b928ee-1e87-4b28-8b71-be97082da028
primary_tag: marketing
tags: [marketing]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with ig AS (
	select c._id AS profile_id,
		arbitrary(contact.value) AS instagram
	from hive.default.matvw_catalog_profile as c
		cross join unnest(raw_profile_ids) AS cr(rid)
		join hive.default.matvw_raw_profile AS r ON (r._id = rid)
		cross join unnest(r.contacts) AS rc(contact)
	where nullif(contact.value, '') is not null
		and contact.type = 'instagram'
	group by 1
)
select 
    u.id AS user_id, 
    u.email,
    u.fullname AS user_name,
    u.createdat AS user_created_date,
    u.subscriptionstatus AS user_subscription_status,
    s.status AS seat_status,
    s.seatid AS profile_id,
    p.name AS profile_name,
    p.profile_type,
    p.credits_count,
    p.common_credits,
    p.popularity AS profile_popularity,
    teamid,
    defaultteamid,
    teamid <> defaultteamid AS is_b2b_workspace,
    COALESCE(ig.instagram, u.instagram) AS instagram
FROM "production-musomvp"."public_users" AS u
	left join "production-musomvp"."public_team_users" AS tu ON (u.id = userid)
	left join "production-musomvp"."public_roster_seats" AS s USING (teamid)
	left join hive.default."matvw_catalog_profile" AS p ON (s.seatid=p._id)
	left join ig on (p._id=ig.profile_id)
where date_diff('day', CAST(SUBSTR(u.createdat, 1, 10) AS date), current_date) < 7
order by u.createdat desc