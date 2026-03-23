/*
id: monthly_by_payment_and_plan
title: [Reporting] Monthly by payment and plan
athena_id: 49deb09b-5843-4665-96c4-2c3b11bbf2f5
primary_tag: reporting
tags: [reporting]
athena_database: platform-import-payments-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select platform,
	CASE
		"sku"
		WHEN 'muso_individual_pro_monthly' THEN 'Pro Monthly'
		WHEN 'muso_individual_pro_monthly_notrial' THEN 'Pro Monthly'
		WHEN 'muso_individual_pro_annual' THEN 'Pro Annual'
		WHEN 'muso_individual_proplus_monthly' THEN 'Pro Plus Monthly'
		WHEN 'muso_individual_proplus_monthly_notrial' THEN 'Pro Plus Monthly'
		WHEN 'muso_individual_proplus_annual' THEN 'Pro Plus Annual'
	END AS plan,
	SUM(price * (num_purchased - num_refunded)) AS revenue,
	SUM(price * num_purchased) AS revenue_gross,
	SUM(price * num_refunded) AS refunds_gross,
	SUM(num_purchased) AS num_purchased,
	SUM(num_refunded) AS num_refunded
from (
		select "sku",
			'iOS' AS platform,
			CASE
				"sku"
				WHEN 'muso_individual_pro_monthly' THEN 9.99
				WHEN 'muso_individual_pro_monthly_notrial' THEN 9.99
				WHEN 'muso_individual_pro_annual' THEN 89.99
				WHEN 'muso_individual_proplus_monthly' THEN 39.99
				WHEN 'muso_individual_proplus_monthly_notrial' THEN 39.99
				WHEN 'muso_individual_proplus_annual' THEN 349.99
			END AS price,
			SUM(
				IF(cast(units AS INT) > 0, cast(units AS INT), 0)
			) AS num_purchased,
			SUM(
				IF(cast(units AS INT) < 0, - cast(units AS INT), 0)
			) AS num_refunded
		from "apple_payments"
		where date_parse("end date", '%m/%d/%Y') between DATE('2023-03-01') and DATE('2023-03-31')
			and CAST("developer proceeds" AS DOUBLE) <> 0
		group by 1
		union all
		select "sku id" AS sku,
			'Android' AS platform,
			CASE
				"sku id"
				WHEN 'muso_individual_pro_monthly' THEN 9.99
				WHEN 'muso_individual_pro_monthly_notrial' THEN 9.99
				WHEN 'muso_individual_pro_annual' THEN 89.99
				WHEN 'muso_individual_proplus_monthly' THEN 39.99
				WHEN 'muso_individual_proplus_monthly_notrial' THEN 39.99
				WHEN 'muso_individual_proplus_annual' THEN 349.99
			END AS price,
			COUNT_IF("financial status" = 'Charged') AS num_purchased,
			COUNT_IF("financial status" = 'Refund') AS num_refunded
		from "google_payments"
		where date_parse("order charged date", '%Y-%m-%d') between DATE('2023-03-01') and DATE('2023-03-31')
		group by 1
	)
GROUP BY 1,
	2
union all
select 'PayPal' AS platform,
	'Boomer Monthly' AS plan,
	SUM(
		CAST(
			transaction_info.transaction_amount.value AS DOUBLE
		)
	) AS revenue,
	SUM(
		IF(
			CAST(
				transaction_info.transaction_amount.value AS DOUBLE
			) > 0,
			CAST(
				transaction_info.transaction_amount.value AS DOUBLE
			),
			0
		)
	) AS revenue_gross,
	SUM(
		IF(
			CAST(
				transaction_info.transaction_amount.value AS DOUBLE
			) < 0,
			- CAST(
				transaction_info.transaction_amount.value AS DOUBLE
			),
			0
		)
	) AS refunds_gross,
	COUNT_IF(
		CAST(
			transaction_info.transaction_amount.value AS DOUBLE
		) > 0
	) AS num_purchased,
	COUNT_IF(
		CAST(
			transaction_info.transaction_amount.value AS DOUBLE
		) < 0
	) AS num_refunded
from "paypal_payments"
where from_iso8601_timestamp(transaction_info.transaction_initiation_date) between DATE('2023-03-01') and DATE('2023-03-31')
	AND transaction_info.transaction_subject LIKE '%Muso.AI Pro%'
group by 1
union all
select 'Stripe' AS platform,
	'Boomer Monthly' AS plan,
	SUM(
		CAST(payment.amount AS DOUBLE) / 100.0
	) AS revenue,
	SUM(
		IF(
			CAST(payment.amount AS DOUBLE) > 0,
			CAST(payment.amount AS DOUBLE) / 100.0,
			0
		)
	) AS revenue_gross,
	SUM(
		IF(
			CAST(payment.amount AS DOUBLE) < 0,
			- CAST(payment.amount AS DOUBLE) / 100.0,
			0
		)
	) AS refunds_gross,
	COUNT_IF(CAST(payment.amount AS DOUBLE) > 0) AS num_purchased,
	COUNT_IF(CAST(payment.amount AS DOUBLE) < 0) AS num_refunded
from "stripe_payments"
	cross join unnest(charges.data) AS p(payment)
WHERE from_unixtime(payment.created) between DATE('2023-03-01') and DATE('2023-03-31')
	and lower(payment.description) LIKE '%subscription%'
order by 1,
	2