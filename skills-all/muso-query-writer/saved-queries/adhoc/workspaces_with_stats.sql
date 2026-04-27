/*
id: workspaces_with_stats
title: [adhoc] Workspaces with stats
athena_id: 4e0aec68-4062-495c-ac9b-ed63276bb4c6
primary_tag: adhoc
tags: [adhoc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with w AS (
	select t.id AS workspace_id,
		arbitrary(t.email) AS email,
		arbitrary(t.name) AS name,
		MAX_BY(s.status, s.createdat) AS subscription_status,
		MAX_BY(s.plan, s.createdat) AS plan,
		array_agg(distinct seatid) AS profile_ids,
		array_agg(distinct IF(rs.status = 'active', seatid)) AS active_profile_ids,
		count(distinct u.id) AS num_users
	from "production-musomvp".public_teams as t
		left join public_roster_seats as rs ON (t.id = rs.teamid)
		left join public_subscriptions as s ON (t.id = s.teamid)
		left join public_team_users as u ON (t.id = u.teamid)
	group by 1
),
wt AS (
	select workspace_id,
		count(distinct master_track_id) AS num_tracks
	from hive."platform-industry-bi-prod".matvw_catalog_profile AS p
		join (
			select profile_id,
				workspace_id
			from w
				cross join unnest(active_profile_ids) as p(profile_id)
			where profile_id is not null
		) ON(p._id = profile_id)
		join hive."platform-industry-bi-prod".matvw_catalog_master_credit AS c using(profile_id)
	where not p.is_deleted
	group by 1
)
select workspace_id,
	arbitrary(w.name) AS name,
	arbitrary(email) AS email,
	arbitrary(subscription_status) AS subscription_status,
	arbitrary(plan) AS plan,
	arbitrary(num_users) AS num_users,
	arbitrary(num_tracks) AS num_tracks,
	count(distinct _id) AS num_profiles,
	count(distinct if(profile_type = 'organization', _id)) AS num_orgs,
	AVG(p.popularity) AS avg_profile_popularity
from hive."platform-industry-bi-prod".matvw_catalog_profile AS p
	join (
		select _id,
			w.*
		from w
			cross join unnest(active_profile_ids) as p(_id)
		where _id is not null
	) AS w USING(_id)
	join wt USING(workspace_id)
where not is_deleted
group by 1
order by num_tracks desc