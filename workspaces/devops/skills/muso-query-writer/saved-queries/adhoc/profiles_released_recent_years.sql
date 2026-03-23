/*
id: profiles_released_recent_years
title: [adhoc] Profiles released recent years
athena_id: de32cafc-1b32-4145-aa26-c8e8628e9711
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-netflix-testdev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    count(1) AS num,
    count_if(num_released_5y > 0) AS num_released_5y,
    count_if(num_released_3y > 0) AS num_released_3y,
    count_if(num_released_1y > 0) AS num_released_1y
from (
select
    tp.profile_id,
    count_if(
    DATE(from_unixtime(t.release_timestamp / 1000)) > date('2019-03-30')
    ) AS num_released_5y,
    count_if(
    DATE(from_unixtime(t.release_timestamp / 1000)) > date('2021-03-30')
    ) AS num_released_3y,
    count_if(
    DATE(from_unixtime(t.release_timestamp / 1000)) > date('2023-03-30')
    ) AS num_released_1y
from "platform-industry-bi-prod".matvw_catalog_track as t
	cross join unnest(profiles) as _tp(tp)
	join "platform-industry-bi-prod".matvw_catalog_profile as p ON (
		tp.profile_id=p._id
	)
where 
    -- p.rank <= 3
    p.popularity > 40
	and not p.is_deleted
	and not t.is_deleted
	group by 1
	)