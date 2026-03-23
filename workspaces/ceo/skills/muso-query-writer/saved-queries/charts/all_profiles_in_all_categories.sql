/*
id: all_profiles_in_all_categories
title: [charts] ALL profiles in all categories
athena_id: 992de93f-54a2-4a7f-bd1c-fd377d8a8686
primary_tag: charts
tags: [charts]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

CREATE TABLE "sandbox-oleg"."adhoc_charts_20230712" WITH (
	external_location = 's3://databaseslake/sandbox-oleg/charts/20230712',
	format = 'JSON',
	partitioned_by = ARRAY [ 'category' ],
	bucket_count = 1,
	bucketed_by = ARRAY [ 'profile_id' ]
) AS
select
	profile_id,
	type,
	name,
	"avatar_url",
	position,
	position_change,
	score,
	score_change,
	"credits_count",
	"credits_count_change",
	category
from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
where date in (
		select max(date)
		from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
	)
	and "position" <= 20000
order by category,
	position