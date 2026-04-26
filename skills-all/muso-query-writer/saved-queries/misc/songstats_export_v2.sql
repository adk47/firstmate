/*
id: songstats_export_v2
title: SongStats Export V2
athena_id: 88f4d33e-de23-4333-a2c0-edc0c8936c13
primary_tag: misc
tags: [misc]
trino_catalog: postgresql_analytics
trino_schema: public
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with usr AS (
	select id as user_id,
		email,
		fullname AS name,
		CAST(createdat AS TIMESTAMP) AS user_create_date,
		CAST(trialexpiredat AS TIMESTAMP) AS trial_expired_date
	from "production-musomvp"."public_users"
),
final AS (
	select name,
		COALESCE(
			last_subscription_status,
			last_user_status
		) AS subscription_status,
		COALESCE(
			reported_payment,
			IF(last_user_status = 'PRO', 9.99, 0)
		) AS reported_amount_v2,
		case
			when COALESCE(last_subscription_status, last_user_status) LIKE '%CANCEL%' then last_payment
			WHEN COALESCE(last_subscription_status, last_user_status) IN ('PRO') THEN IF(
				is_boomer,
				IF(
					COALESCE(last_payment, 9.99) > 9.99,
					ceiling((last_payment -9.99) / 6.99) * 6.99 + 9.99,
					9.99 + LEAST(
						(
							GREATEST(COALESCE(last_seats_num, 0), 2) -2
						),
						5
					) * 6.99
				),
				COALESCE(last_payment, 9.99)
			) else 0
		end AS reported_amount,
		last_tracks_num,
		is_boomer
	from "bi"."user_daily_stats"
		JOIN usr USING(user_id)
	WHERE DATE(date_column) = date('2022-10-31')
)
select name,
	IF(
		subscription_status = 'CANCELLED',
		'PRO',
		subscription_status
	) AS subscription_status,
	CAST(
		IF(
			is_boomer,
			GREATEST(CEIL((reported_amount - 9.99) / 6.99), 0),
			IF(reported_amount > 9.99, 5, 1)
		) AS INT
	) AS boomer_discovery_seats,
	if(
		is_boomer,
		IF(
			subscription_status IN ('PRO', 'CANCELLED'),
			'old_pro',
			'old_trial'
		),
		IF(
			subscription_status IN ('PRO', 'CANCELLED'),
			IF(reported_amount > 9.99, 'PRO_PLUS', 'PRO'),
			'TRIAL'
		)
	) AS user_payment_status,
	reported_amount AS payment,
	last_tracks_num AS num_tracks
from final
WHERE subscription_status IN ('PRO', 'TRIAL')
	OR subscription_status = 'CANCELLED'
	and reported_amount > 0