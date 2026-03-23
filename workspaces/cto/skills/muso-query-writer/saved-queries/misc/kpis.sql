/*
id: kpis
title: KPIs
athena_id: 6e2ed845-6184-44a8-83ef-2ebdd9a896c6
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select count(1) AS num_users,
	count(subscriptionstatus) AS num_was_trial,
	count_if(subscriptionstatus IN ('TRIAL')) AS num_trial,
	COUNT_IF(subscriptionstatus IN ('PRO', 'CANCELLED')) AS num_was_pro,
	COUNT_IF(subscriptionstatus IN ('PRO')) AS num_pro,
	COUNT_IF(subscriptionstatus IN ('CANCELLED')) AS num_cancelled,
	COUNT_IF(subscriptionstatus IN ('EXPIRED')) AS num_expired,
	1.0 * COUNT_IF( 
	    DATE(createdatdate) >= CURRENT_DATE - INTERVAL '30' day
	    AND subscriptionstatus IS NOT NULL
    ) / COUNT_IF( 
	    DATE(createdatdate) >= CURRENT_DATE - INTERVAL '30' day
    ) AS registered2trial,
	1.0 * COUNT_IF( 
	    DATE(createdatdate) >= CURRENT_DATE - INTERVAL '30' day
	    AND subscriptionstatus IN ('PRO', 'CANCELLED')
    ) / COUNT_IF( 
	    DATE(createdatdate) >= CURRENT_DATE - INTERVAL '30' day
	    AND subscriptionstatus IS NOT NULL
    ) AS trial2paid
from "production-musomvp"."public_users"