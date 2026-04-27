/*
id: potential_fraud_accounts_muso_only_credits
title: [Fraud] Potential fraud accounts - muso only credits
athena_id: 632bae80-1ba9-4352-8655-8f893535d16f
primary_tag: fraud
tags: [fraud]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with 
mp as (
    select distinct profileid as profile_id
    from postgresql_core.public.claiming
    where status = 'processed' and profiletype <> 'organization'
),
rp as (
	select raw_profile_id,
		profile_id,
		common_credits as profile_common_credits,
		popularity as profile_popularity,
		name as profile_name
	from hive."platform-industry-bi-prod".matvw_catalog_profile
		cross join unnest(raw_profile_ids) as r(raw_profile_id)
		join mp ON (profile_id=_id)
	where not is_deleted
),
rt as (
	select raw_recording_id,
		_id as track_id,
		max(popularity) as track_popularity,
		min(title) as track_title
	from hive."platform-industry-bi-prod".matvw_catalog_track
		cross join unnest(raw_recording_ids) as r(raw_recording_id)
	where not is_deleted
	group by 1,
		2
),
rc as (
	select profile_id as raw_profile_id,
		recording_id as raw_recording_id,
		recording_id like 'muso%'
		and profile_id like 'muso%' as is_muso,
		coalesce(try(from_unixtime(created_timestamp/1000)) < date('2023-10-01'), TRUE) as is_before_credit_verification
	from hive."platform-industry-bi-prod".matvw_raw_recording_credit
),
m as (
	select profile_id,
		track_id,
		count_if(not is_muso) = 0 as is_muso_only,
		count_if(not (is_muso and is_before_credit_verification)) = 0 as is_muso_only_before_credit_verification,
		max(track_popularity) as track_popularity,
		min(track_title) as track_title,
		arbitrary(profile_popularity) as profile_popularity,
		arbitrary(profile_common_credits) as profile_common_credits,
		arbitrary(profile_name) as profile_name
	from rc
		join rp USING(raw_profile_id)
		join rt USING(raw_recording_id)
	group by 1,
		2
)
select
    profile_id,
    profile_name,
    profile_popularity,
    profile_common_credits,
    total_track_popularity,
    muso_only_track_popularity,
    100 * muso_only_track_popularity / total_track_popularity as pct_muso_only_popularity,
    100 * muso_only_track_popularity_before_verification / total_track_popularity as pct_muso_only__before_verification_popularity,
    cnt_tracks,
    cnt_muso_only,
    cnt_before_credit_verification
from (
    select 
        profile_id,
		arbitrary(profile_popularity) as profile_popularity,
		arbitrary(profile_common_credits) as profile_common_credits,
		arbitrary(profile_name) as profile_name,
        sum(track_popularity) as total_track_popularity,
        sum(if(is_muso_only, track_popularity, 0)) as muso_only_track_popularity,
        sum(if(is_muso_only_before_credit_verification, track_popularity, 0)) as muso_only_track_popularity_before_verification,
        count(1) as cnt_tracks,
        count_if(is_muso_only) as cnt_muso_only,
        count_if(is_muso_only_before_credit_verification) as cnt_before_credit_verification
    from m 
    group by 1
)
where total_track_popularity > 50 and 100 * muso_only_track_popularity / total_track_popularity > 50
order by 8 desc, 7 desc, 5 desc