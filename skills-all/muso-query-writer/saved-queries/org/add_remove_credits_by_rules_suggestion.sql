/*
id: add_remove_credits_by_rules_suggestion
title: [org] Add/remove credits by rules suggestion
athena_id: f5cd5f82-9baf-4b5e-a3e9-8f759866ae5c
primary_tag: org
tags: [org]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with o AS (
	select t.id AS workspace_id,
		arbitrary(t.name) AS workspace_name,
		arbitrary(if(type = 'organization', seatid)) AS org_id,
		array_agg(seatid) AS profile_ids
	from postgresql_core.public.roster_seats AS s
		join postgresql_core.public.teams AS t ON (teamid = t.id)
	where status = 'active'
	group by 1
	having count_if(type = 'organization') = 1
),
op AS (
	select filter(
			common_credits,
			cc->cc in (
				'Publisher',
				'Record Label',
				'Management Company'
			)
		) AS common_credits,
		name AS org_name,
		o.*
	from o
		join hive."platform-industry-bi-prod".matvw_catalog_profile ON (_id = org_id)
),
pc AS (
	select master_track_id AS track_id,
		org_id,
		arbitrary(org_name) AS org_name,
		arbitrary(workspace_name) AS workspace_name
	from hive."platform-industry-bi-prod".matvw_catalog_master_credit
		join (
			select profile_id,
				org_id,
				org_name,
				workspace_name,
				transform(
					common_credits,
					c->CASE
						c
						when 'Publisher' then 'Songwriter'
						when 'Record Label' then 'Artist'
						when 'Management Company' then '$ALL_CREDITS$'
					END
				) AS parents
			from op
				cross join unnest(profile_ids) AS p(profile_id)
			where cardinality(common_credits) > 0
		) USING(profile_id)
	where contains(parents, '$ALL_CREDITS$')
		OR cardinality(
			array_intersect(
				parents,
				transform(catalog_credits, c->c.parent)
			)
		) > 0
	group by 1,
		2
),
oc AS (
	select master_track_id AS track_id,
		org_id,
		arbitrary(org_name) AS org_name,
		arbitrary(workspace_name) AS workspace_name
	from hive."platform-industry-bi-prod".matvw_catalog_master_credit
		join op ON (profile_id = org_id)
	where cardinality(common_credits) > 0
	group by 1,
		2
),
t AS (
	select COALESCE(oc.workspace_name, pc.workspace_name) AS workspace_name,
		COALESCE(oc.org_name, pc.org_name) AS org_name,
		track_id,
		IF(oc.org_name is NULL, 'add', 'remove') AS track_status
	from oc
		full outer join pc USING(org_id, track_id)
	where oc.org_name is null
		or pc.org_name is null
)
select workspace_name,
	org_name,
	track_status,
	title,
	array_join(array_distinct(transform(artists, a->a.name)), ', ') AS artists,
	popularity,
	'https://credits.muso.ai/track/' || track_id AS track_url
from t
join hive."platform-industry-bi-prod".matvw_catalog_track ON (_id=track_id)
order by 1,2,3, popularity desc