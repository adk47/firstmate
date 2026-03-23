/*
id: muso_user_profiles_with_org_credits
title: [adhoc] Muso User Profiles with org credits
athena_id: 877dc162-33d2-4f68-b466-ee257e7b71b2
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with c AS (
	select profile_id AS _id,
	    count(1) AS num_tracks_have_org,
	    count_if(cardinality(
	    filter(catalog_credits, c->c.parent <> 'Organizations')
	) = 0) AS num_tracks_org_only
	from matvw_catalog_master_credit
	where cardinality(
	    filter(catalog_credits, c->c.parent='Organizations')
	) > 0
	group by 1
), s AS (
    select 
        seatid as _id, 
        TRUE AS in_seats ,
        BOOL_OR(COALESCE(status='active', false)) AS has_analytics
    from "platform-core-backend-export-prod".public_roster_seats
    group by 1
)
select 
    _id AS profile_id,
    name,
    popularity,
    has_analytics,
    num_tracks_org_only,
    num_tracks_have_org,
    credits_count
from matvw_catalog_profile AS p 
join c USING(_id)
join s USING(_id)