/*
id: all_transactions
title: All Transactions
athena_id: ede460d2-a45b-4957-b850-0053b8258bfc
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr_trans AS (
	select user_id,
		service,
		CAST(transactiondate AS TIMESTAMP) AS transaction_date,
		period_start,
		period_end,
		is_trial,
		case
			when is_trial then 0
			when plan in ('muso_individual_proplus_monthly') then 39.99
			when plan in ('muso_individual_pro_monthly') then 9.99
			when service = 'stripe' then amount / 100 else amount
		end AS amount,
		COALESCE(plan, 'boomer') AS plan,
		transactionid AS transaction_id
	from (
			select userid as user_id,
				service,
				transactionid,
				CAST(
					json_extract(paymentdetails, '$.amount') AS DOUBLE
				) AS amount,
				CAST(
					json_extract(paymentdetails, '$.currency') AS VARCHAR
				) AS currency,
				CAST(
					json_extract(paymentdetails, '$.plan') AS VARCHAR
				) AS plan,
				transactiondate,
				DATE_DIFF('day', DATE("periodstart"), DATE("periodend")) <= 9 AS is_trial,
				DATE(periodstart) AS period_start,
				DATE(periodend) AS period_end
			from "production-musomvp"."public_payment_history"
			where transactionstatus = 'succeeded'
		)
),
usr_date_trans AS (
	select user_id,
		date(transaction_date) AS date_column,
		ARRAY_AGG(DISTINCT transaction_id) AS transaction_ids,
		MAX(transaction_date) AS last_transaction_date,
		SUM(amount) AS total_payment
	from usr_trans
	group by 1,
		2
)
select *
from usr_trans
where transaction_date between DATE('2022-07-01') and DATE('2022-08-01')
order by transaction_date desc