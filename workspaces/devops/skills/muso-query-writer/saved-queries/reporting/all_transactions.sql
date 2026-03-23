/*
id: all_transactions
title: [Reporting] All transactions
athena_id: 7c1536a9-c64c-4602-8ee1-1d203a5b51a8
primary_tag: reporting
tags: [reporting]
athena_database: platform-import-payments-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select 'iOS' AS platform,
	"sku",
	date_parse("end date", '%m/%d/%Y') AS date,
	CASE
		"sku"
		WHEN 'muso_individual_pro_monthly' THEN 9.99
		WHEN 'muso_individual_pro_monthly_notrial' THEN 9.99
		WHEN 'muso_individual_pro_annual' THEN 89.99
		WHEN 'muso_individual_proplus_monthly' THEN 39.99
		WHEN 'muso_individual_proplus_monthly_notrial' THEN 39.99
		WHEN 'muso_individual_proplus_annual' THEN 349.99
	END AS price,
	cast(units AS INT) AS units
from "apple_payments"
where date_parse("end date", '%m/%d/%Y') between DATE('2023-03-01') and DATE('2023-03-31')
	and CAST("developer proceeds" AS DOUBLE) <> 0
union all
select 'Android' AS platform,
	"sku id" AS sku,
	date_parse("order charged date", '%Y-%m-%d') AS date,
	CASE
		"sku id"
		WHEN 'muso_individual_pro_monthly' THEN 9.99
		WHEN 'muso_individual_pro_monthly_notrial' THEN 9.99
		WHEN 'muso_individual_pro_annual' THEN 89.99
		WHEN 'muso_individual_proplus_monthly' THEN 39.99
		WHEN 'muso_individual_proplus_monthly_notrial' THEN 39.99
		WHEN 'muso_individual_proplus_annual' THEN 349.99
	END AS price,
	IF("financial status" = 'Charged', 1, -1) AS units
from "google_payments"
where date_parse("order charged date", '%Y-%m-%d') between DATE('2023-03-01') and DATE('2023-03-31')
union all
select 'PayPal' AS platform,
	'muso_individual_pro_monthly' AS sku,
	date(
		from_iso8601_timestamp(transaction_info.transaction_initiation_date)
	) AS date,
	CAST(
		transaction_info.transaction_amount.value AS DOUBLE
	) AS price,
	1 AS units
from "paypal_payments"
where from_iso8601_timestamp(transaction_info.transaction_initiation_date) between DATE('2023-03-01') and DATE('2023-03-31')
	AND transaction_info.transaction_subject LIKE '%Muso.AI Pro%'
union all
select 'Stripe' AS platform,
	'muso_individual_pro_monthly' AS sku,
	date(from_unixtime(payment.created)) AS date,
	CAST(payment.amount AS DOUBLE) / 100.0 AS price,
	1 as units
from "stripe_payments"
	cross join unnest(charges.data) AS p(payment)
WHERE from_unixtime(payment.created) between DATE('2023-03-01') and DATE('2023-03-31')
	and lower(payment.description) LIKE '%subscription%'
order by 3, 1, 2