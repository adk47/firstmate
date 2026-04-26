/*
id: adhoc_credit_requests_queries
title: [reporting] AdHoc - credit requests queries
athena_id: 6cf4ebb7-0163-47c5-bed7-49b66e54b45c
primary_tag: reporting
tags: [reporting]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select * from postgresql_core.public.public_credit_requests 
limit 10

-- summary
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    try_cast(
        json_extract(spotifytrackartists, '$') AS array(ROW(
            id varchar,
            name varchar
        ))
    ) AS artists,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    coalesce(spotifypopularity, 0) AS spotify_popularity,
    try_cast(json_extract(verificationdata, '$') AS ROW(
        is_approved boolean,
        rule_risk_percent map(varchar, double),
        total_risk_percent double,
        credit_rule_risk_percent MAP(varchar, map(varchar, double))
    )) AS verif_data,
    id
from postgresql_core.public.public_credit_requests 
),
ce AS (
    select 
        distinct profileid, trackid, child AS credit, TRUE as is_on_source
    from hive.default.matvw_raw_recording_credit
    join (
    select 
        profile_id,
        _id AS profileid
    from hive.default.matvw_catalog_profile
    cross join unnest (raw_profile_ids) AS r(profile_id)
    where profile_id not like 'muso:%'
    ) USING(profile_id)
    join (
    select 
        recording_id,
        _id AS trackid
    from hive.default.matvw_catalog_track
    cross join unnest (raw_recording_ids) AS r(recording_id)
    where recording_id not like 'muso:%'
    ) USING(recording_id)
    join (
    select 
        _id AS credit,
        c.child AS child
    from "platform-industry-db-industry-prod".dict_credit
    cross join unnest (catalog_credits) AS r(c)
    ) USING(credit)
)
select 
    count(distinct row(id, credit)) AS num_credit_requests,
    count(distinct if(is_on_source, row(id, credit))) AS num_credit_requests_on_source,
    count(distinct id) AS num_requests,
    count(distinct trackid) AS num_tracks,
    count(distinct userid) AS num_users,
    count(distinct profileid) AS num_profiles,
    count(distinct artist.id) AS num_artists,
    count(distinct IF(status='approved', id)) AS num_approved,
    count(distinct IF(verif_data.is_approved, id)) AS num_auto_approved
from cr 
cross join unnest(credits) AS a(credit)
left join ce USING(profileid, trackid, credit)
cross join unnest(artists) AS a(artist)
-- where status='approved'
group by 1
order by 2 desc
limit 1000

-- artists
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    try_cast(
        json_extract(spotifytrackartists, '$') AS array(ROW(
            id varchar,
            name varchar
        ))
    ) AS artists,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    coalesce(spotifypopularity, 0) AS spotify_popularity,
    try_cast(json_extract(verificationdata, '$') AS ROW(
        is_approved boolean,
        rule_risk_percent map(varchar, double),
        total_risk_percent double,
        credit_rule_risk_percent MAP(varchar, map(varchar, double))
    )) AS verif_data,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    artist.name AS artist_name,
    count(1) AS num_requests,
    count(distinct trackid) AS num_tracks,
    count(distinct userid) AS num_users,
    count_if(status='approved') AS num_approved,
    count_if(verif_data.is_approved) AS num_auto_approved
from cr 
cross join unnest(artists) AS a(artist)
-- where status='approved'
group by 1
order by 2 desc
limit 1000

-- users
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    coalesce(spotifypopularity, 0) AS spotify_popularity,
    try_cast(json_extract(verificationdata, '$') AS ROW(
        is_approved boolean,
        rule_risk_percent map(varchar, double),
        total_risk_percent double,
        credit_rule_risk_percent MAP(varchar, map(varchar, double))
    )) AS verif_data,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    fullname AS user_name,
    count(1) AS num_requests,
    count(distinct trackid) AS num_tracks,
    count_if(status='approved') AS num_approved,
    count_if(verif_data.is_approved) AS num_auto_approved,
    count(distinct cr.id) AS num_requests
from cr 
join postgresql_core.public.public_users AS u ON (u.id=userid)
-- where status='approved'
group by 1
order by 2 desc

-- initial status
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    coalesce(spotifypopularity, 0) AS spotify_popularity,
    try_cast(json_extract(verificationdata, '$') AS ROW(
        is_approved boolean,
        rule_risk_percent map(varchar, double),
        total_risk_percent double,
        credit_rule_risk_percent MAP(varchar, map(varchar, double))
    )) AS verif_data,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    IF(verif_data.is_approved, 'auto-approved', 'verification-needed') AS initial_status,
    status AS status,
    count(distinct id) AS num_requests
from cr 
-- where status='approved'
group by 1,2
order by 3 desc

-- track popularity
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    coalesce(spotifypopularity, 0) AS spotify_popularity,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    popularity,
    count(distinct id) AS num_requests
from cr 
join (
    select 
        _id as trackid,
        coalesce(popularity, 0) AS popularity,
        coalesce(rank, 5) AS rank
    from hive.default.matvw_catalog_track
    -- where not is_deleted
) using(trackid)
where status='approved'
group by 1 
order by 2 desc

-- Requests by profile data
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    coalesce(spotifypopularity, 0) AS spotify_popularity,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    spotify_popularity,
    count(distinct id) AS num_requests
from cr 
-- join (
--     select 
--         _id as profileid,
--         coalesce(popularity, 0) AS popularity,
--         coalesce(rank, 5) AS rank
--     from hive.default.matvw_catalog_profile
--     -- where not is_deleted
-- ) using(profileid)
where status='approved'
group by 1 
order by 2 desc

-- Requests by profile data
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    popularity,
    count(distinct id) AS num_requests
from cr 
join (
    select 
        _id as profileid,
        coalesce(popularity, 0) AS popularity,
        coalesce(rank, 5) AS rank
    from hive.default.matvw_catalog_profile
    -- where not is_deleted
) using(profileid)
where status='approved'
group by 1 
order by 2 desc


-- Requests by child credit
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day,
    split(substr(credits, 2, length(credits)-2), ',') AS credits,
    id
from postgresql_core.public.public_credit_requests 
)
select 
    parent,
    count(distinct id) AS num_requests
from cr 
cross join unnest(credits) AS c(credit)
join (
    select 
        lower(_id) AS l_credit,
        cc.parent
    from "platform-industry-db-industry-prod".dict_credit
    cross join unnest(catalog_credits) AS c(cc)
    -- where cc.parent = 'Musician'
) on (lower(credit)=l_credit)
where status='approved'
group by 1 
order by 2 desc

-- Requests by date (day)
with cr AS (
select 
    profileid,
    userid,
    trackid,
    status,
    substr(createdat, 1, 10) AS day 
from postgresql_core.public.public_credit_requests 
)
select 
    day,
    count(1) AS num_requests,
    sum(count(1)) over (order by day) AS cum_num_requests
from cr
group by 1
order by day desc