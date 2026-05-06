/*
id: isrcs_track_industry_wide_catalog
title: [Audit] Isrcs/track industry-wide catalog
athena_id: c50ab718-7d6a-48bf-823a-ca5456d99d01
primary_tag: audit
tags: [audit]
athena_database: audit-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- ISRC
select case
		when not in_mlc then 'ISRC missing'
		when not has_work then 'Unmatched Recording'
	end as action,
	count(1) as num_isrcs,
	count_if(isrc_popularity > 0) as num_isrcs_1_popularity,
	count_if(isrc_popularity >= 10) as num_isrcs_10_popularity,
	count_if(isrc_popularity >= 20) as num_isrcs_20_popularity,
	count_if(isrc_popularity >= 50) as num_isrcs_50_popularity,
	sum(streams_weighted) as streams_weighted
from "audit-prod".audit_isrc_track
where track_rank = 1
group by 1
-- TRACK
select case
		when length(coalesce(mlc_isrcs, ''))=0 then 'Unregistered isrcs'
		when not has_work then 'Unmatched Recordings'
		when length(coalesce(missing_isrcs, ''))>0 then 'Missing Recordings on Exising Works'
	end as action,
	count(1) as num_tracks,
	count_if(track_popularity > 0) as num_tracks_popularity,
	count_if(track_popularity >= 10) as num_tracks_10_popularity,
	count_if(track_popularity >= 20) as num_tracks_20_popularity,
	count_if(track_popularity >= 50) as num_tracks_50_popularity,
	sum(streams) as streams
from "audit-prod".audit_track
group by 1

select * from "audit-prod".audit_track limit 10