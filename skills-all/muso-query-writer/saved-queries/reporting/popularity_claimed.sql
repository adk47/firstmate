/*
id: popularity_claimed
title: [reporting] Popularity claimed %
athena_id: f1a0e703-ca56-4f8e-a01b-e9a9d71b9dfe
primary_tag: reporting
tags: [reporting]
athena_database: production-musomvp
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select popularity,
	count(1) AS num,
	count(is_claimed) AS num_claimed,
	count(in_seats) AS num_in_seats
from hive.default.matvw_catalog_profile
	left join (
		select distinct profileid as _id,
			TRUE as is_claimed
		from public_claiming
		where status = 'processed'
	) USING(_id)
	left join (
		select distinct seatid as _id,
			TRUE as in_seats
		from public_roster_seats
		where status = 'active'
	) USING(_id)
where not is_deleted
	and popularity is not null
group by 1
order by 1 desc