/*
id: top_100_per_chart
title: [Charts] Top 100 per chart
athena_id: ba9fc66f-f112-43fa-bd22-2f868f3fd950
primary_tag: charts
tags: [charts]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with cs AS (
	select credit,
		profile_id AS _id,
		score.score,
		score.track_count,
		row_number() over (
			partition by credit
			order by score.score desc, score.track_count desc
		) AS row_num
	from "platform-industry-calc-prod".calc_credit_score
		cross join unnest(
			CAST(
				json_extract("child_credit_score", '$') AS MAP(varchar, ROW(score bigint, track_count bigint))
			)
		) AS m(credit, score) -- 	where credit = 'Artist'
)
select credit,
	row_num,
	_id AS profile_id,
	name,
	score,
	track_count,
	'https://open.spotify.com/artist/' || try(
		split_part(
			filter(raw_profile_ids, p->p like 'spotify:%') [ 1 ],
			':',
			2
		)
	) AS spotify_url,
	'https://listen.tidal.com/artist/' || try(
		split_part(
			filter(raw_profile_ids, p->p like 'tidal:%') [ 1 ],
			':',
			2
		)
	) AS tidal_url,
	try(images[1].url) AS image
from "platform-industry-db-industry-prod".catalog_profile
	join cs USING(_id)
where row_num <= 100
order by row_num