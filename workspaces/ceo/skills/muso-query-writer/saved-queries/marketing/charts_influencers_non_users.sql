/*
id: charts_influencers_non_users
title: [marketing] Charts Influencers (non-users)
athena_id: 1c4debb9-6af9-4183-8591-320648f25382
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
		TRY(
			FILTER(contacts, c->c.type = 'instagram') [ 1 ].value
		) AS profile_instagram,
		TRY(
			FILTER(contacts, c->c.type = 'facebook') [ 1 ].value
		) AS profile_facebook,
		TRY(
			FILTER(contacts, c->c.type = 'twitter') [ 1 ].value
		) AS profile_twitter,
		TRY(
			FILTER(contacts, c->c.type = 'website') [ 1 ].value
		) AS profile_website
	FROM "platform-industry-db-industry-prod"."catalog_profile" AS p
		left join "production-musomvp"."public_users" AS u ON (u."neptuneprofessionalid" = p._id)
	where u.id is NULL
),
ch AS (
	select profile_id,
		arbitrary(profile_name) AS profile_name,
		arbitrary(profile_instagram) AS profile_instagram,
		arbitrary(profile_facebook) AS profile_facebook,
		arbitrary(profile_twitter) AS profile_twitter,
		MIN_BY(category, position) AS top_category,
		MIN(position) AS top_category_position,
		MIN_BY(score, position) AS top_category_score,
		map_agg(category, position) AS top_categories_positions
	from (
			select *,
				row_number() over (
					partition by category
					order by position
				) AS num
			from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history" AS c
				join usr USING(profile_id)
			where date in (
					select max(date)
					from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
				)
				and position <= 3000
		)
	where num <= 200
	group by profile_id
)
select *
from ch
order by top_category_position,
	top_category_score desc