/*
id: songstats_payments
title: SongStats payments
athena_id: 3572477a-f840-451f-acb7-e50f3f2429eb
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select id AS user_id,
		email,
		fullname AS name,
		subscriptionstatus AS subscription_status,
		NULLIF(COALESCE(appledata, googledata), '') is NULL AS is_boomer,
		element_at(
			COALESCE(
				CAST(
					json_extract(
						stripedata,
						'$.previousSubscriptions'
					) AS array(json)
				),
				COALESCE(
					CAST(
						json_extract(
							paypaldata,
							'$.previousSubscriptions'
						) AS array(json)
					),
					COALESCE(
						CAST(
							json_extract(
								appledata,
								'$.previousSubscriptions'
							) AS array(json)
						),
						COALESCE(
							CAST(
								json_extract(
									googledata,
									'$.previousSubscriptions'
								) AS array(json)
							),
							ARRAY [ ]
						)
					)
				)
			),
			-1
		) AS payment_json
	from "production-musomvp"."public_users"
),
usr_seats AS (
	select userid AS user_id,
		count(1) AS total_seats_num,
		count_if(
			status = 'active'
			AND deletedat is NULL
		) AS paid_seats_num,
		filter(
			ARRAY_AGG(
				DISTINCT IF(
					status = 'active'
					AND deletedat is NULL,
					seatid
				)
			),
			e->e IS NOT NULL
		) AS profile_ids
	from "production-musomvp"."public_discovery_seats"
	GROUP BY 1
),
prof_tracks AS (
	select distinct profile_id,
		track_id
	from (
			SELECT profileid as profile_id,
				MAX_BY(
					SPLIT(substr(tracksids, 2, LENGTH(tracksids) -2), ','),
					date
				) as track_ids
			FROM "production-musomvp"."public_profile_analytics_stats_history"
			group by 1
		)
		CROSS JOIN UNNEST(track_ids) AS t(track_id)
),
tracks AS (
	select user_id,
		count(distinct(track_id)) as num_tracks
	FROM usr_seats AS s
		JOIN prof_tracks AS t ON (array_position(profile_ids, profile_id) > 0)
	group by 1
),
usr_trans AS (
	select user_id,
		ARRAY_AGG(DISTINCT transactionid) AS transaction_ids,
		MAX(transactiondate) AS last_transaction_date,
		SUM(
			IF(
				service = 'stripe',
				trans.amount / 100,
				trans.amount
			)
		) AS total_payment
	from (
			select userid as user_id,
				service,
				transactionid,
				CAST(
					json_parse(paymentdetails) AS ROW(amount double, currency varchar)
				) AS trans,
				transactiondate
			from "production-musomvp"."public_payment_history"
			where transactiondate between '2022-07-01' and '2022-08-01'
				and transactionstatus = 'succeeded'
		)
	group by 1
)
select name,
	subscription_status,
	COALESCE(
		CAST(
			json_extract(payment_json, '$.seatsCount') AS INT
		),
		0
	) AS boomer_discovery_seats,
	LOWER(
		CAST(
			json_extract(payment_json, '$.subscriptionStatus') AS VARCHAR
		)
	) AS last_payment_status,
	CASE
		WHEN is_boomer THEN 'BOOMER'
		when paid_seats_num > 1 THEN 'PRO_PLUS' else 'PRO'
	END AS user_payment_status,
	CASE
		WHEN subscription_status = 'TRIAL' THEN 0
		WHEN is_boomer
		AND total_payment > 0 THEN total_payment
		WHEN is_boomer THEN COALESCE(
			CAST(
				json_extract(payment_json, '$.seatsCount') AS INT
			),
			0
		) * 6.99 + 9.99
		WHEN paid_seats_num > 1 THEN 39.99 else 9.99
	end AS payment,
	last_transaction_date,
	num_tracks,
	email
from usr
	FULL OUTER JOIN usr_trans USING(user_id)
	LEFT JOIN usr_seats USING(user_id)
	LEFT JOIN tracks USING(user_id)
where (
		last_transaction_date is not null
		OR subscription_status IN ('PRO', 'TRIAL')
	)