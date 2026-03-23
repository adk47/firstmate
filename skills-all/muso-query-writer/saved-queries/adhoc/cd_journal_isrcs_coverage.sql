/*
id: cd_journal_isrcs_coverage
title: [adhoc] CD Journal ISRCs coverage
athena_id: de3b843b-00d7-46c0-8b11-35bae140085c
primary_tag: adhoc
tags: [adhoc]
athena_database: neptune-edges-json-production
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with isrcs AS (select col0 as isrc
from adhoc.adhoc 
where 
    partition_0 ='cd_journal_isrcs' and col0 <> 'isrc'
), 
_track_isrc AS (
	select distinct
	    tr."~from" AS track_id,
	    isrcs.isrc
	from "neptune-nodes-json-production"."recording" AS r
	join "neptune-edges-json-production"."hasrecording"  AS tr ON (r."~id"=tr."~to")
	right join isrcs ON (r."~id"=isrcs.isrc)
),
tracks AS (
	select isrc,
	    count(track_id) > 0 AS has_track,
		COUNT_IF(
			lower(parent) LIKE '%producer%'
			or lower(child) like '%producer%'
		) > 0 AS has_producer,
		COUNT_IF(lower(parent) LIKE '%engineer%') > 0 AS has_engineer,
		COUNT_IF(lower(parent) LIKE '%writer%') > 0 AS has_songwriter
	from "neptune-edges-json-production"."collaborateover"
		RIGHT JOIN _track_isrc ON("~to" = track_id)
	GROUP BY 1
)
select has_track, has_producer, has_engineer, has_songwriter, count(1) from tracks
group by 1, 2, 3, 4
order by count(1) desc