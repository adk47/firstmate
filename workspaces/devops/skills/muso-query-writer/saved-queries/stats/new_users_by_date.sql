/*
id: new_users_by_date
title: [stats] New users by date
athena_id: 7874d137-d9f0-4cd0-969b-edcbf049d0bd
primary_tag: stats
tags: [stats]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select created_date,
	num AS new,
	SUM(num) over (
		ORDER BY created_date rows unbounded preceding
	) AS total
from (
		select COALESCE(
				CAST(SUBSTR(createdat, 1, 10) AS date),
				date('2018-06-27')
			) AS created_date,
			count(1) AS num
		from "production-musomvp".public_users
		group by 1
	)
order by 1 desc