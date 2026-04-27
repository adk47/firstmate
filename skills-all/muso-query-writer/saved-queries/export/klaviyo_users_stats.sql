/*
id: klaviyo_users_stats
title: [export] Klaviyo users stats
athena_id: 6c15ec0e-70e0-4144-9123-ed50a130fdcb
primary_tag: export
tags: [export]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select u.id AS user_id,
		ARBITRARY(u.email) AS user_email,
		ARBITRARY(u.subscriptionstatus) AS user_status,
		ARBITRARY(sb.status) AS workspace_status,
		ARBITRARY(sb.plan) AS workspace_plan,
		ARBITRARY(u."fullname") AS user_name,
		MAX(s.status) AS seat_status,
		BOOL_OR(
			COALESCE(u.neptuneprofessionalid = s.seatid, c.id is not null, false)
		) AS is_profile_claimed,
		MAX_BY(
			p._id,
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_id,
		MAX_BY(
			p.name,
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_name,
		MAX_BY(
			p.popularity,
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_popularity,
		MAX_BY(
			ARRAY_JOIN(
				transform(
					p.common_credits,
					c->IF(c like 'Producer%', 'Producer', c)
				),
				', '
			),
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_common_credits,
		MAX_BY(
			p.credits_count,
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_credits_count,
		MAX_BY(
			p.collaborations_count,
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_collaborations_count,
		MAX_BY(
			TRY(
				array_sort(
					p.images,
					(x, y)->if(
						coalesce(try_cast(x.width."$numberint" AS int), 0) > coalesce(try_cast(y.width."$numberint" AS int), 0),
						-1,
						1
					)
				) [ 1 ].url
			),
			ROW(
				IF(
					u.neptuneprofessionalid = s.seatid,
					IF(p.credits_count > 0, 1, 0),
					0
				),
				IF(s.status = 'active', 1, 0),
				coalesce(p.popularity, 0),
				COALESCE(p._id, '')
			)
		) AS profile_image
	FROM "production-musomvp"."public_users" AS u
	    left join "production-musomvp"."public_team_users" AS tu ON (u.id=tu.userid)
	    left join "production-musomvp"."public_subscriptions" AS sb ON (sb.teamid=tu.teamid)
		left join "production-musomvp"."public_roster_seats" AS s ON (tu.teamid = s.teamid)
		left join hive."platform-industry-bi-prod"."matvw_catalog_profile" AS p ON (
			COALESCE(s.seatid, u."neptuneprofessionalid") = p._id
		)
		left join "production-musomvp"."public_claiming" as c ON (tu.teamid=c.teamid and p._id=c.profileid)
	group by 1
),
ch AS (
	select MIN_BY(category, position) AS top_category,
		profile_id,
		MIN(position) AS top_category_position,
		MIN_BY(position_change, position) AS top_category_position_change,
		MIN_BY(score, position) AS top_category_score
	from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
	where date in (
			select max(date)
			from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
		)
	group by profile_id
)
select *
from usr
	left join ch USING(profile_id)
order by if(seat_status = 'active', 0, 1),
	profile_popularity desc