/*
id: claiming_coverage_py_popularity_group
title: [reporting] Claiming coverage py popularity group
athena_id: 2d4a914b-a812-4060-9b6e-e6194f75229e
primary_tag: reporting
tags: [reporting]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/


select 
    popularity,
    cum_num,
    cum_claimed,
    cum_in_seats,
    round(100.0 * cum_num / MAX(cum_num) over(), 3) AS market_percent,
    round(100.0 * cum_claimed / cum_num, 3) AS claimed_penetration,
    round(100.0 * cum_in_active_seats / cum_num, 3) AS active_seats_penetration,
    round(100.0 * cum_in_seats / cum_num, 3) AS seats_penetration
from (
		select *,
			SUM(num) OVER(
				order by popularity desc rows unbounded preceding
			) AS cum_num,
			SUM(num_claimed) OVER(
				order by popularity desc rows unbounded preceding
			) AS cum_claimed,
			SUM(num_in_seats) OVER(
				order by popularity desc rows unbounded preceding
			) AS cum_in_seats,
			SUM(num_in_active_seats) OVER(
				order by popularity desc rows unbounded preceding
			) AS cum_in_active_seats
		from (
				select coalesce(popularity, 0) AS popularity,
					count(1) AS num,
					count(is_claimed) AS num_claimed,
					count_if(in_seats) AS num_in_seats,
					count_if(in_active_seats) AS num_in_active_seats
				from "platform-industry-bi-prod".matvw_catalog_profile
					left join (
						select distinct profileid as _id,
							TRUE as is_claimed
						from public_claiming
						where status = 'processed'
					) USING(_id)
					left join (
						select distinct seatid as _id,
						    status = 'active' AS in_active_seats,
							TRUE as in_seats
						from public_roster_seats
					) USING(_id)
				where not is_deleted
				group by 1
			)
	)
where LEAST(99, popularity) % 10 = 0
order by popularity desc