/*
id: test_1
title: [credits verification] Test 1
athena_id: 4e069102-f0bc-4fbb-9dac-489b0eb594dd
primary_tag: credits-verification
tags: [credits-verification]
athena_database: platform-industry-bi-dev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with m AS (
	select split_part(profile_id, ':', 2) as profile_id,
		split_part(recording_id, ':', 2) as track_id,
		credit as credit_id
	from matvw_raw_recording_credit
	where not coalesce(is_deleted, false)
		and recording_id like 'muso:%'
		and profile_id like 'muso:%'
),
pc AS (
	select collaborator_id AS profile_id,
		filter(
			ARRAY_AGG(
				distinct try(
					filter(collaborator_ids, c->c <> collaborator_id) [ 1 ]
				)
			),
			p->p is not null
		) AS profile_collaborator_ids
	from matvw_catalog_collaboration
		cross join unnest(collaborator_ids) AS t(collaborator_id)
	group by 1
),
pcc AS (
	select profile_id,
		histogram(credit.child) AS child_nums,
		count(1) AS num_credits
	from matvw_catalog_master_credit AS c
		cross join unnest (catalog_credits) AS cc(credit)
	group by 1
),
tc AS (
	select master_track_id AS track_id,
		filter(
			array_agg(IF(p.profile_type = 'artist', p._id)),
			p->p is not null
		) AS track_artist_ids,
		filter(
			array_agg(
				IF(
					cardinality(
						filter(
							c.catalog_credits,
							cc->cc.child = 'Mixing'
						)
					) > 0,
					p._id
				)
			),
			p->p is not null
		) AS mixing_profile_ids,
		filter(
			array_agg(
				IF(
					cardinality(
						filter(
							c.catalog_credits,
							cc->cc.child = 'Mastering'
						)
					) > 0,
					p._id
				)
			),
			p->p is not null
		) AS mastering_profile_ids,
		filter(array_agg(profile_id), p->p is not null) AS track_profile_ids
	from matvw_catalog_master_credit AS c
		join matvw_catalog_profile AS p ON (p._id = profile_id)
	where not coalesce(c.is_deleted, false)
	group by 1
),
pr AS (
	select profile_id,
		max(release_timestamp) AS max_track_release_timestamp,
		approx_percentile(release_timestamp, 0.95) AS p95_track_release_timestamp
	from matvw_catalog_track
		cross join unnest (
			array_union(
				transform(profiles, p->p.profile_id),
				transform(artists, p->p.catalog_profile_id)
			)
		) AS p(profile_id)
	group by 1
),
main as (
	select profile_id,
		track_id,
		credit_id AS credit,
		coalesce(t.popularity, 0) AS track_popularity,
		p.profile_type = 'organization' AS auto_approve,
		try(c.catalog_credits [ 1 ].parent = 'Artist') AS auto_reject,
		least(
			20,
			coalesce(t.popularity, 0) / (coalesce(p.popularity, 0) + 1)
		) AS pt_popularity_pct,
		least(
			20,
			greatest(
				0,
				(
					t.release_timestamp - p95_track_release_timestamp
				) / 1000 / (60 * 60 * 24 * 12)
			)
		) AS pt_release_pct,
		IF(
			cardinality(
				array_except(track_artist_ids, profile_collaborator_ids)
			) > 0,
			15,
			0
		) + 15 * cardinality(
			array_except(track_profile_ids, profile_collaborator_ids)
		) / (cardinality(profile_collaborator_ids) + 1) as pt_collab_pct,
		20 - 20 * (
			1 + num_credits - coalesce(
				try(child_nums [ c.catalog_credits [ 1 ].child ]),
				0
			)
		) / (num_credits + 1) AS pc_pct,
		IF(
			try(c.catalog_credits [ 1 ].child) = 'Mastering'
			AND cardinality(
				array_except(mastering_profile_ids, array [ profile_id ])
			) > 0,
			10,
			0
		) AS tc_mastering_pct,
		IF(
			try(c.catalog_credits [ 1 ].child) = 'Mixing'
			AND cardinality(
				array_except(mixing_profile_ids, array [ profile_id ])
			) > 0,
			10,
			0
		) AS tc_mixing_pct,
		IF(
			try(c.catalog_credits [ 1 ].parent) in ('Producers & Arrengers', 'Songwriter'),
			10,
			0
		) AS tc_scary_pct
	from m
		join matvw_catalog_track AS t ON (t._id = track_id)
		join matvw_catalog_profile AS p ON (p._id = profile_id)
		join matvw_dict_credit AS c ON (c._id = credit_id)
		LEFT join tc USING(track_id)
		LEFT join pc USING(profile_id)
		LEFT join pcc USING(profile_id)
		LEFT join pr USING(profile_id)
)
select
    count(1) AS num_credits,
    count_if(total_pct >= 30) AS total_30_plus,
    count_if(total_pct >= 50) AS total_50_plus,
    count_if(pt_popularity_pct >= 10) AS pt_popularity_pct,
    count_if(pt_release_pct >= 10) AS pt_release_pct,
    count_if(pt_collab_pct >= 10) AS pt_collab_pct,
    count_if(pc_pct >= 10) AS pc_pct,
    count_if(tc_mastering_pct >= 10) AS tc_mastering_pct,
    count_if(tc_mixing_pct >= 10) AS tc_mixing_pct,
    count_if(tc_scary_pct >= 10) AS tc_scary_pct
from (
		select log10(track_popularity + 10) * (
				COALESCE(pt_popularity_pct, 0) + coalesce(pt_release_pct, 0) + coalesce(pt_collab_pct, 0) + coalesce(pc_pct, 0) + coalesce(tc_mastering_pct, 0) + coalesce(tc_mixing_pct, 0) + coalesce(tc_scary_pct, 0)
			) AS total_pct,
			*
		from main
	)