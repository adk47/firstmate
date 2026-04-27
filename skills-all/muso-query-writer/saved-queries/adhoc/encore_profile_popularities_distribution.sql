/*
id: encore_profile_popularities_distribution
title: [AdHoc] Encore profile popularities distribution
athena_id: 2e47eb06-16a9-4850-acee-f3ca99dab014
primary_tag: adhoc
tags: [adhoc]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with s AS (
	select seatid,
		date(cast(createdat as timestamp)) AS seat_added_date,
		createdat,
		teamid
	from postgresql_core.public.roster_seats
	where status = 'active'
)
select 
    case 
        -- when seat_added_date < DATE('2022-12-01') then '1. Pre ENCORE 22'
        -- when seat_added_date < DATE('2023-01-31') then '2. ENCORE 22'
        when seat_added_date < DATE('2023-12-01') then '1. Pre ENCORE 23'
        when seat_added_date < DATE('2024-01-31') then '2. ENCORE 23'
        else '3. After ENCORE 23'
    end,
    count(1) AS num_seats_added,
    count_if(popularity >= 90) AS popularity_90,
    count_if(popularity between 80 and 89) AS popularity_80,
    count_if(popularity between 70 and 79) AS popularity_70,
    count_if(popularity between 60 and 69) AS popularity_60,
    count_if(popularity between 50 and 59) AS popularity_50,
    count_if(popularity between 40 and 49) AS popularity_40,
    count_if(popularity between 30 and 39) AS popularity_30,
    count_if(popularity between 20 and 29) AS popularity_20,
    count_if(popularity between 10 and 19) AS popularity_10,
    count_if(coalesce(popularity, 0) < 10) AS popularity_0,
    AVG(popularity) AS avg_popularity,
    approx_percentile(popularity, 0.25) AS p25_popularity,
    approx_percentile(popularity, 0.5) AS p50_popularity,
    approx_percentile(popularity, 0.75) AS p75_popularity,
    approx_percentile(popularity, 0.9) AS p90_popularity
from hive."platform-industry-bi-prod".matvw_catalog_profile AS p
join s ON (seatid=_id) 
group by 1 
order by 1