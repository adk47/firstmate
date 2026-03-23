/*
id: top_influecners
title: [marketing] Top Influecners
athena_id: 59baa8fc-17ab-4fbe-999a-0885d3a4e801
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select p._id AS profile_id,
		p.name AS profile_name,
		u.email AS user_email,
		u.subscriptionstatus AS user_status,
		TRY(FILTER(contacts, c->c.type='instagram')[1].value) AS profile_instagram,
		TRY(FILTER(contacts, c->c.type='facebook')[1].value) AS profile_facebook,
		TRY(FILTER(contacts, c->c.type='twitter')[1].value) AS profile_twitter,
		TRY(FILTER(contacts, c->c.type='website')[1].value) AS profile_website
	FROM "platform-industry-db-industry-prod"."catalog_profile" AS p
		left join "production-musomvp"."public_users" AS u ON (u."neptuneprofessionalid" = p._id)
),
ch AS (
	select profile_id,
		MIN_BY(category, position) AS top_category,
		MIN(position) AS top_category_position,
		MIN_BY(score, position) AS top_category_score,
		map_agg(category, position) AS top_categories_positions
	from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
	where date in (
			select max(date)
			from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
		)
		and position <= 300
	group by profile_id
)
select *
from usr
	right join ch USING(profile_id)
order by top_category_position,
	top_category_score desc