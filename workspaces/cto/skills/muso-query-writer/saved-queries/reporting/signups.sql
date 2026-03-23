/*
id: signups
title: [reporting] SignUps
athena_id: 4629cab2-4498-43b0-ab24-924b09f7db69
primary_tag: reporting
tags: [reporting]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select substr(cast(date as varchar), 1, 7) AS month,
	sum(num) AS num,
	MAX(cum_num) AS cum_num
from (
		select date,
			count(1) AS num,
			SUM(count(1)) over (
				order by date rows unbounded preceding
			) AS cum_num
		from (
				select email,
					MIN(date(cast(createdat as timestamp))) AS date
				from public_users
				group by 1
			)
		group by 1
	)
	where date > date('2022-10-30')
group by 1
order by 1 desc