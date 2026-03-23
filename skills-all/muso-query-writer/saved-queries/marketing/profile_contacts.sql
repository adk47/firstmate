/*
id: profile_contacts
title: [marketing] Profile Contacts
athena_id: 0e89413a-4e11-4a8b-9283-0a293b354b0c
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with claimed as (
	select profileid as profile_id,
		max_by(verificationlinks, createdat) AS claim_verification_links,
		TRUE as is_claimed
	from "production-musomvp".public_claiming
	where status = 'processed'
	group by 1
),
pro AS (
	select seatid as profile_id,
		TRUE AS is_pro
	from "production-musomvp".public_roster_seats
	where status = 'active'
	group by 1
)
select c._id AS profile_id,
	arbitrary(c.name) AS name,
	arbitrary(c.popularity) AS popularity,
	arbitrary(c.rank) AS rank,
	BOOL_OR(COALESCE(is_claimed, FALSE)) AS is_claimed,
	BOOL_OR(COALESCE(is_pro, FALSE)) AS is_pro,
	arbitrary(IF(contact.type = 'instagram', contact.value)) AS instagram,
	arbitrary(IF(contact.type = 'facebook', contact.value)) AS facebook,
	arbitrary(IF(contact.type = 'twitter', contact.value)) AS twitter,
	arbitrary(IF(contact.type = 'website', contact.value)) AS website,
	arbitrary(claim_verification_links) AS claim_verification_links
from "platform-industry-bi-prod".matvw_catalog_profile as c
	left join pro ON(c._id = pro.profile_id)
	left join claimed ON(c._id = claimed.profile_id)
	cross join unnest(raw_profile_ids) AS cr(rid)
	join "platform-industry-bi-prod".matvw_raw_profile AS r ON (r._id = rid)
	cross join unnest(r.contacts) AS rc(contact)
where nullif(contact.value, '') is not null
	OR NULLIF(claim_verification_links, '') is not null
group by 1
order by 3 desc