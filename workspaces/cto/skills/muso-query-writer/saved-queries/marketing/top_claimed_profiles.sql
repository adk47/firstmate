/*
id: top_claimed_profiles
title: [Marketing] Top claimed profiles
athena_id: def632eb-31b3-4060-b321-470f414ce7d0
primary_tag: marketing
tags: [marketing]
athena_database: platform-core-backend-export-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with claimed as (
	select profileid as profile_id,
		min_by(verificationlinks, c.createdat) AS claim_verification_links,
		TRUE as is_claimed,
		min_by(t.email, c.createdat) as claim_email
	from "platform-core-backend-export-prod".public_claiming as c
	join "platform-core-backend-export-prod".public_teams as t ON (c.teamid=t.id)
	where c.status = 'processed'
	group by 1
),
pro AS (
	select seatid as profile_id,
		TRUE AS is_pro
	from "platform-core-backend-export-prod".public_roster_seats
	where status = 'active'
	group by 1
)
select c._id AS profile_id,
	IF(arbitrary(c.profile_type) = 'organization', 'company', 'artist') AS profile_type,
	arbitrary(c.name) AS name,
	arbitrary(c.popularity) AS popularity,
	arbitrary(c.rank) AS rank,
	arbitrary(claim_email) AS email,
	BOOL_OR(COALESCE(is_pro, FALSE)) AS is_pro,
	arbitrary(IF(contact.type = 'instagram', contact.value)) AS instagram,
	arbitrary(IF(contact.type = 'facebook', contact.value)) AS facebook,
	arbitrary(IF(contact.type = 'twitter', contact.value)) AS twitter,
	arbitrary(IF(contact.type = 'website', contact.value)) AS website,
	arbitrary(claim_verification_links) AS claim_verification_links
from "platform-industry-bi-prod".matvw_catalog_profile as c
	join claimed ON(c._id = claimed.profile_id)
	left join pro ON(c._id = pro.profile_id)
	cross join unnest(raw_profile_ids) AS cr(rid)
	join "platform-industry-bi-prod".matvw_raw_profile AS r ON (r._id = rid)
	cross join unnest(r.contacts) AS rc(contact)
group by 1
order by 4 desc