/*
id: credit_subset_create
title: Credit Subset Create
athena_id: 582f65cb-7cff-4d0b-8617-fb04d8056a6e
primary_tag: misc
tags: [misc]
athena_database: platform-data-merging-catalog-dev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- CREATE TABLE "sandbox-oleg"."industry_db_credit__subset" WITH (
-- 	external_location = 's3://databaseslake/sandbox-oleg/catalog/industry_db/industry_db_credit__subset/',
-- 	format = 'JSON'
-- ) AS
-- select *
-- from postgresql_industry.public."catalog_industry_db_credit"
-- where profile_id in (
-- 		'ff7a7b1c-6e11-4390-b08e-e62de4bb16ca', -- Jay
-- 		'c9b9b1d4-dc8d-4cc9-aa5d-1b03089aeb7d' -- Mr. Probz
-- 	)
	
CREATE TABLE "sandbox-oleg"."industry_db_recording__subset" WITH (
	external_location = 's3://databaseslake/sandbox-oleg/catalog/industry_db/industry_db_recording__subset/',
	format = 'JSON'
) AS
select master_id,
	r.*
from postgresql_industry.public."catalog_industry_db_recording" AS r
	JOIN "sandbox-oleg"."industry_db_credit__subset" USING(master_id)