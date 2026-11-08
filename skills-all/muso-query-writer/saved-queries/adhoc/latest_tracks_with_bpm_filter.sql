/*
id: latest_tracks_with_bpm_filter
title: [adhoc] Latest tracks with bpm filter
athena_id: 5b60f57e-e6f4-4784-9296-010bfd29be7b
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with rec AS (
	select "_id",
		raw_artist_ids,
		TRY(
			split_part(
				filter("raw_recording_ids", r->r like 'spotify:%') [ 1 ],
				':',
				2
			)
		) AS spotify_id,
		array_join(transform("artists", a->a.name), ', ') AS artists,
		DATE(
			from_unixtime(
				cast(release_date."$date"."$numberLong" AS BIGINT) / 1000
			)
		) AS "release_date",
		"title",
		TRY_CAST(popularity."$numberInt" AS int) AS popularity,
		TRY_CAST(audio_features.tempo."$numberDouble" AS double) AS tempo
	from "platform-industry-db-industry-prod"."catalog_track"
),
g AS (
	select p._id,
		array_agg(
			distinct lower(COALESCE(genre.primary_genre, gnr))
		) AS genres
	from "platform-industry-db-industry-prod"."raw_profile" AS p
		cross join unnest(genres) AS g(gnr)
		join "platform-industry-db-industry-prod"."dict_genre" AS dg ON(lower(dg._id) = lower(gnr))
		cross join unnest(catalog_genres) AS cg(genre)
	group by 1
)
select ARBITRARY(title) as "Track Name",
	ARBITRARY(artists) AS "Artists",
	'https://open.spotify.com/track/' || spotify_id AS "Spotify URL",
	MAX(popularity) as "Popularity",
	MAX("release_date") AS "Release Date",
	ARBITRARY(tempo) AS "BPM",
	'https://muso.ai/track/' || ARBITRARY(rec._id) AS "Muso URL",
	array_join(ARBITRARY(genres), ', ') AS "Genres"
from rec
	left join g ON (CONTAINS(rec."raw_artist_ids", g._id))
where release_date between date_add('day', -30, current_date)
	and current_date
	and (
		tempo between 170 and 174
		or tempo between 85 and 87
	)
group by spotify_id
order by "Popularity" desc