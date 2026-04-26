/*
id: top_muso_profiles_by_ig_followers
title: [Encore] Top Muso profiles by IG followers
athena_id: 0ca07c2c-b7cb-4c61-81cb-b68744f3117a
primary_tag: encore
tags: [encore]
athena_database: platform-industry-zyteig-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with 
pa as (
    select  
        profile_id,
        popularity, 
        primary_genre,
        try(
            array_sort(
                cast(json_parse(child_roles) as array(row(child varchar, credit_count int, credit_count_1y int, parent varchar))), 
                 (c1, c2)->if(c1.credit_count < c2.credit_count, 1, -1)
            )[1].child
        ) as primary_role
    from "platform-industry-calc-prod".profile_aggregations_full 
    join (select max(build_timestamp) as build_timestamp from "platform-industry-calc-prod"."profile_aggregations_full$partitions" ) USING(build_timestamp)
),
p as (
    select 
        _id as profile_id,
        profile_type,
        name
    from hive.default.matvw_catalog_profile
    where not is_deleted
),
ig as (
    select 
        reverse(split_part(reverse(rtrim(url, '/')), '/', 1)) as ig_handle,
        max_by(follower_count, import_date) as ig_followers,
        max_by(post_count, import_date) as ig_posts
    from "platform-industry-zyteig-bi-prod".instagram_profile
    where import_date is not null
    group by 1
),
pig as (
    select 
        profile_id,
        ig_handle,
        ig_followers,
        ig_posts
    from (
        select distinct
            _id as profile_id,
            reverse(split_part(reverse(rtrim(contact.value, '/')), '/', 1)) as ig_handle
        from "platform-industry-db-industry-prod".catalog_profile
        cross join unnest(contacts) AS rc(contact)
        where 
            contact.type = 'instagram' 
            and not coalesce(deleted.is_deleted, false)
            and nullif(contact.value, '') is not null
    ) join ig USING(ig_handle)
),
claimed as (
	select profileid as profile_id,
		TRUE as is_claimed,
		min_by(t.email, nullif(c.createdat, '2025-12-31')) as claim_email
	from postgresql_core.public.public_claiming as c
	join postgresql_core.public.public_teams as t ON (c.teamid=t.id)
	where c.status = 'processed'
	group by 1
),
pro AS (
	select seatid as profile_id,
		BOOL_OR(status = 'active') AS is_pro,
		TRUE as in_roster
	from postgresql_core.public.public_roster_seats
	group by 1
)
select 
-- *
    profile_id,
    'https://credits.muso.ai/profile/'||profile_id as muso_url,
	name,
	profile_type,
	primary_genre,
	primary_role,
	'https://instagram.com/'||ig_handle as ig_url,
	ig_followers,
	ig_posts,
	popularity,
	is_claimed,
	in_roster,
	is_pro,
	claim_email
from p
left join pa USING(profile_id)
left join pig USING(profile_id)
	left join claimed USING(profile_id)
	left join pro USING(profile_id)
where ig_followers > 10000 or (is_claimed and popularity > 30)
order by ig_followers desc, popularity desc