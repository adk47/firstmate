/*
id: all_emails_list
title: [marketing] All Emails list
athena_id: 08db1545-1299-45f4-b161-c70c72ac4ec9
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select distinct email
from (
		select email
		from postgresql_core.public.public_users
		union all
		select email
		from postgresql_core.public.public_teams
	)
where email not like '%appleid%' and email not like '%muso%'