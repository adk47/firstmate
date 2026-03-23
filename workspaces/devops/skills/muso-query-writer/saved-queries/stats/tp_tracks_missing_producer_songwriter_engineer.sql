/*
id: tp_tracks_missing_producer_songwriter_engineer
title: [stats] Tp tracks missing producer, songwriter, engineer
athena_id: e77c0c3c-302d-4126-afc7-e9691fe18e40
primary_tag: stats
tags: [stats]
athena_database: platform-industry-bi-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select *
from (
		select cat,
			track_id,
			title,
			artists,
			popularity,
			label,
			row_number() over (
				partition by cat
				order by popularity desc
			) as r_n
		from (
				select _id as track_id,
					map(
						array [ 'no_swr',
						'no_prd',
						'no_eng' ],
						array [ num_swr = 0,
						num_prd = 0,
						num_eng = 0 ]
					) as t,
					title,
					array_join(transform(artists, a->a.name), ',') AS artists,
					default_release_label as label, 
					popularity
				from (
						select master_track_id as _id,
							count_if(cr.parent = 'Songwriter') as num_swr,
							count_if(lower(cr.parent) like '%producer%') as num_prd,
							count_if(lower(cr.parent) like '%engineer%') as num_eng
						from matvw_catalog_master_credit as c
							cross join unnest (catalog_credits) as cc(cr)
						group by 1
					)
					join matvw_catalog_track as t USING(_id)
				where popularity > 50
					and not is_deleted
					and (
						num_swr = 0
						or num_prd = 0
						or num_eng = 0
					)
			)
			cross join unnest(t) as m(cat, is_mis)
		where is_mis
	)
where r_n <= 30