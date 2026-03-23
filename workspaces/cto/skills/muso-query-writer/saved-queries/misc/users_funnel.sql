/*
id: users_funnel
title: Users Funnel
athena_id: 26198f96-02c7-4255-97f9-79473f5f3189
primary_tag: misc
tags: [misc]
athena_database: staging-songstats-data
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
 createdatdate AS registration_date,
  count(1) AS num_registered,
 COUNT_IF(emailconfirmed) AS num_email_confirmed, 
 COUNT_IF(subscriptionstatus = 'TRIAL') AS num_trial, 
 COUNT_IF(subscriptionstatus = 'PRO') AS num_pro
from "production-musomvp"."public_users" 
WHERE 
    createdatdate > '2021-12-31'
group by 1