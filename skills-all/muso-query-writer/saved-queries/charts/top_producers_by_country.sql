/*
id: top_producers_by_country
title: [charts] Top PRODUCERs by country
athena_id: 9bcd13d4-1357-4d41-8e7f-1d51a9a865c4
primary_tag: charts
tags: [charts]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select country,
	country_position,
	position,
	profile_id,
	name,
	score,
	'https://credits.muso.ai/profile/' || profile_id as muso_url
from (
		select row_number() over (
				partition by country
				order by position
			) AS country_position,
			*
		from (
				select case
						when country like 'Moldova%' then 'Moldova'
						when country like 'Korea%' then 'Korea'
						when country like 'Russia%' then 'Russia'
						when country like 'Trinidad%' then 'Trinidad and Tobago'
						when country like 'United States%' then 'United States'
						when country like 'United Kingdom%' then 'United Kingdom'
						when country like 'Venezuela%' then 'Venezuela' else country
					end as country,
					position,
					profile_id,
					p.name,
					score
				from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history" AS s
					join hive.default.matvw_catalog_profile AS p ON (s.profile_id = p._id)
				where date = '2024-11-28'
					and category in ('Producer')
			)
	)
where country_position <= 100
	and position <= 100000
order by country,
	country_position