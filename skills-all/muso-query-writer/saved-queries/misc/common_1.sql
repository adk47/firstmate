/*
id: common_1
title: [User Requests] Common 1
athena_id: a2d5f70e-11cd-4b24-a05b-cdcb1a48ba9e
primary_tag: user-requests
tags: [user-requests]
athena_database: platform-industry-zyteig-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select 
    *
from "platform-industry-calc-prod".calc_analytics_links_merge_history 
where date > '2025-04-15' and entity.entity_id='bc11b773-17ab-4ba9-bae5-1bf3530a61d5'
order by date desc

select 
    *
from "platform-industry-zyteig-bi-prod".instagram_reels 
where import_date > '2025-04-01' 
and audio_id=632566784064754
order by import_date desc
limit 100

select count(1) from postgresql_industry.public."zyte_capture__ig_messages"


select
from ""