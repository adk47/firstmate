/*
id: claiming
title: [revalidation] Claiming
athena_id: 07e7208c-eaa8-47e0-8ce9-0b0e24d1a701
primary_tag: revalidation
tags: [revalidation]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p AS (
	select _id AS profileid,
		_id as profile_id
	from hive."platform-industry-bi-prod".matvw_catalog_profile as p
	where not p.is_deleted
	union
	select split_part(pid, ':', 2) AS profileid,
		_id as profile_id
	from hive."platform-industry-bi-prod".matvw_catalog_profile as p
		cross join unnest(raw_profile_ids) AS r(pid)
	where not p.is_deleted
		and pid like 'muso:'
),
m AS (
	select distinct profile_id,
		array_agg(member_id) AS members,
		count(1) AS num_members
	from "platform-industry-db-industry-prod".catalog_member
	where not coalesce(deleted.is_deleted, false)
	group by 1
),
mo AS (
	select distinct member_id AS profile_id,
		array_agg(profile_id) AS member_ofs,
		count(1) AS num_member_ofs
	from "platform-industry-db-industry-prod".catalog_member
	where not coalesce(deleted.is_deleted, false)
	group by 1
),
c AS (
	select profile_id,
		max_by(teamid, c.createdat) AS workspace_id,
		max_by(t.name, c.createdat) AS workspace_name,
		max_by(t.email, c.createdat) AS workspace_email,
		array_distinct(
			flatten(
				array_agg(
					filter(
						map_values(
							TRY_CAST(
								json_extract(c.verificationlinks, '$') AS MAP(varchar, varchar)
							)
						),
						v->v is not null
					)
				)
			)
		) AS verification_links
	from p
		right join "production-musomvp".public_claiming AS c USING(profileid)
		join "production-musomvp".public_teams AS t ON (teamid = t.id)
	where nullif(c.deletedat, '') is null
		and c.status = 'processed'
	group by 1
)
select profile_id,
	c.*,
	'https://muso.ai/profile/' || profile_id AS muso_url,
	p.name,
	p.legal_name,
	p.popularity,
	p.credits_count,
	top_category,
	num_members,
	num_member_ofs,
	min_position AS top_category_position,
	cardinality(p.raw_profile_ids) AS num_raw_profiles
from postgresql_industry.public.ops_for_review__staging_profiles AS p
	JOIN c USING(profile_id)
	left join m using(profile_id)
	left join mo using(profile_id)
order by coalesce(cardinality(verification_links), 0),
	num_members desc,
	num_member_ofs desc,
	popularity desc