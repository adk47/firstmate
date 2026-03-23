/*
id: beatstars_bulk_user_matching
title: [AdHoc] Beatstars bulk user matching
athena_id: 73f67940-85d0-4522-97c0-9764fefd4ac8
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-qobuz-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with b as (
	select "member id" as bs_id,
		replace(lower(isrc), '-', '') as isrc,
		coalesce(arbitrary("display name"), arbitrary(username)) as bs_name,
		count() over (partition by "member id") as num_bs_isrcs
	from "adhoc".beatstars_users_matching
	group by 1,
		2
),
n as (
	select m_id,
		array_agg(distinct lower(m_name)) as m_names
	from (
			select p._id as m_id,
				rp.name as m_name
			from "platform-industry-bi-prod".matvw_catalog_profile as p
				cross join unnest(raw_profile_ids) as r(rpid)
				join "platform-industry-bi-prod".matvw_raw_profile as rp ON (rpid = rp._id)
			where not p.is_deleted
				and not rp.is_deleted
				and length(rp.name) > 1
			union all
			select _id as m_id,
				name as m_name
			from "platform-industry-bi-prod".matvw_catalog_profile
			where not is_deleted
				and length(name) > 1
			union all
			select _id as m_id,
				legal_name as m_name
			from "platform-industry-bi-prod".matvw_catalog_profile
			where not is_deleted
				and length(legal_name) > 1
			union all
			select _id as m_id,
				first_name || ' ' || coalesce(last_name, '') as m_name
			from "platform-industry-bi-prod".matvw_catalog_profile
			where not is_deleted
				and length(first_name) > 1
			union all
			select _id as m_id,
				k_name as m_name
			from "platform-industry-bi-prod".matvw_catalog_profile
				cross join unnest(known_as_names) as n(k_name)
			where not is_deleted
				and length(k_name) > 1
		)
	group by 1
),
m as (
	select profile.profile_id as m_id,
		replace(lower(isrc), '-', '') as isrc,
		arbitrary(name) as m_name,
		count() over (partition by profile.profile_id) as num_m_isrcs
	from "platform-industry-bi-prod".matvw_catalog_track as t
		cross join unnest(isrcs) as i(isrc)
		cross join unnest(profiles) as tp(profile)
		join "platform-industry-bi-prod".matvw_catalog_profile as p ON (profile.profile_id = p._id)
	where not p.is_deleted
		and not t.is_deleted
	GROUP BY 1,
		2
),
t as (
	select m_id,
		bs_id,
		arbitrary(m_name) as m_name,
		arbitrary(bs_name) as bs_name,
		count(1) as num_isrcs_match,
		arbitrary(num_m_isrcs) as num_m_isrcs,
		arbitrary(num_bs_isrcs) as num_bs_isrcs,
		1.0 * count(1) / arbitrary(num_bs_isrcs) as pct_isrc_match,
		1.0 * count(1) / arbitrary(num_m_isrcs) as pct_isrc_match_reverse
	from m
		join b USING(isrc)
-- 	where num_bs_isrcs >= 5
	group by 1,
		2
	having 1.0 * count(1) / arbitrary(num_bs_isrcs) > 0.1
)
select 
    bs_id,
    bs_name,
    m_name as muso_name,
    pct_match,
    num_bs_isrcs,
    pct_isrc_match,
    pct_name_diff,
    'https://credits.muso.ai/profile/' || m_id as muso_url
from (
    select
        *,
        pct_isrc_match * (1.0 - least(pct_name_diff, 0.5)) as pct_match,
        row_number() over (partition by bs_id order by pct_isrc_match * (1.0 - least(pct_name_diff, 0.5)) desc, pct_isrc_match_reverse desc) as match_num
    from (
        select m_id,
        	t.*,
        	array_min(
        		transform(
        			m_names,
        			n->1.0 * levenshtein_distance(lower(bs_name), lower(n)) / coalesce(nullif(length(bs_name), 0), 1)
        		)
        	) as pct_name_diff,
        	m_names
        from t
        	join n USING(m_id)
    )
)
where match_num = 1
order by num_bs_isrcs desc