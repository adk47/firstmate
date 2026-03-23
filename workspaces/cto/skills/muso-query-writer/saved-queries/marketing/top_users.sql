/*
id: top_users
title: [marketing] Top Users
athena_id: 49b8d921-d8c1-40a9-8a75-354029db784e
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
		TRY(FILTER(contacts, c->c.type = 'instagram') [ 1 ].value) AS profile_instagram,
		TRY(FILTER(contacts, c->c.type = 'facebook') [ 1 ].value) AS profile_facebook,
		TRY(FILTER(contacts, c->c.type = 'twitter') [ 1 ].value) AS profile_twitter,
		TRY(FILTER(contacts, c->c.type = 'website') [ 1 ].value) AS profile_website
	FROM "platform-industry-db-industry-prod"."catalog_profile" AS p
		join "production-musomvp"."public_users" AS u ON (u."neptuneprofessionalid" = p._id)
),
ch AS (
	select usr.*,
		profile_id,
		category,
		position,
		score,
		row_number() over (
			partition by category
			order by position
		) AS row_num
	from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
		join usr USING(profile_id)
	where date in (
			select max(date)
			from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
		)
)
select profile_id,
	arbitrary(profile_name) AS profile_name,
	arbitrary(user_email) AS user_email,
	arbitrary(user_status) AS user_status,
	MIN_BY(category, position) AS top_category,
	MIN(position) AS top_category_position,
	MIN_BY(score, position) AS top_category_score,
	map_agg(category, position) AS top_categories_positions
from ch
where row_num <= 300
group by profile_id
order by top_category_position,
	top_category_score desc