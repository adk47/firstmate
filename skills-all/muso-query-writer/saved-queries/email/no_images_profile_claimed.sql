/*
id: no_images_profile_claimed
title: [email] No images profile claimed
athena_id: 8347a4ed-7a19-42ae-8df8-540b9b46d8c7
primary_tag: email
tags: [email]
trino_catalog: postgresql_core
trino_schema: public
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select has_image,
	is_pro AS is_in_pro_seats,
	count(1) AS num_profiles
from (
		select p._id AS profile_id,
			count_if(cardinality(p.images) > 0) > 0 AS has_image,
			count_if(s.status = 'active') > 0 AS is_pro
		from postgresql_core.public.claiming AS c
			join hive."platform-industry-bi-prod".matvw_catalog_profile AS p ON (c.profileid = p._id)
			join postgresql_core.public.roster_seats AS s ON (seatid = p._id)
		where c.status = 'processed'
		group by 1
	)
group by 1,
	2