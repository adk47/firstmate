/*
id: postgre_profiles_claimed
title: Postgre - Profiles Claimed
athena_id: 7c7e95f3-70b8-40c3-a1c7-3d4eebe3a9c8
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

SELECT createdat > '2022-02-18' as is_now,
	COUNT(1)
from "public_profile_claiming"
WHERE status = 'processed'
	AND createdat > '2022-01-21'
group by 1