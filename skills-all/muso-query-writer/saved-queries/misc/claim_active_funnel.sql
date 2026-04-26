/*
id: claim_active_funnel
title: Claim, active funnel
athena_id: 58d8e4a3-5121-4a28-94c7-835ce5e97fbb
primary_tag: misc
tags: [misc]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select
    year(date(substr(user_created, 1, 10))) AS date,
    count(1) AS num_users,
    count_if(has_email) AS num_with_email,
    count_if(num_claimed > 0) AS num_with_claimed,
    count_if(num_seats > 0) AS num_with_seats,
    count_if(num_active_seats > 0) AS num_with_active_seats,
    count_if(num_teams > 1) AS num_with_multiple_teams,
    count_if(num_seats > 1) AS num_with_2_plus_seats,
    count_if(num_active_seats > 1) AS num_with_2_plus_active_seats,
    count_if(num_claimed > 1) AS num_with_2_plus_claimed
from (
		select u.id,
		MIN(u.createdat) AS user_created,
			ARBITRARY(u.email) is not null AS has_email,
			COUNT(distinct t.id) as num_teams,
			COUNT(distinct s.seatid) as num_seats,
			COUNT(distinct IF(s.status='active', s.seatid)) as num_active_seats,
			COUNT(distinct c.profileid) as num_claimed
		from postgresql_core.public.public_users as u
			left join postgresql_core.public.public_team_users as tu ON (u.id = tu.userid)
			left join postgresql_core.public.public_teams as t ON (tu.teamid = t.id)
			left join postgresql_core.public.public_roster_seats AS s ON (t.id = s.teamid)
			left join postgresql_core.public.public_claiming AS c ON (
				t.id = c.teamid
				and c.deletedat is null
				and c.status = 'processed'
			)
		group by 1
	)
	group by 1