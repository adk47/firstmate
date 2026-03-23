/*
id: user_statuses_mismatch
title: User Statuses Mismatch
athena_id: e9534dce-6478-4332-97a9-4114ff68e8f4
primary_tag: misc
tags: [misc]
athena_database: bi
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with user_status AS (
	select user_id,
		COALESCE(
			MAX_BY(last_subscription_status, date_column),
			'NULL'
		) AS last_subscription_status
	from "bi"."user_daily_stats"
	group by user_id
),
user AS (
	select "id" AS user_id,
		COALESCE("subscriptionstatus", 'NULL') AS user_status
	from "production-musomvp"."public_users"
)
select *
from user_status
	join user using(user_id)
where last_subscription_status <> user_status