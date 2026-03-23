/*
id: b2b_label_albums_artists
title: B2B - Label Albums Artists
athena_id: 34b1718d-2d92-462e-9deb-6f77980d7543
primary_tag: misc
tags: [misc]
athena_database: platform-data-merging-batch-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with album AS (
	select label,
		id AS album_id,
		name as album_name,
		popularity AS album_popularity,
		genres AS album_genres,
		CARDINALITY(tracks) AS num_tracks,
		IF(release_date > '2022-02-01', TRUE, FALSE) AS recently_released,
		artists,
		ROW_NUMBER() OVER(
			partition by label
			ORDER BY popularity DESC
		) AS top
	from "platform-data-merging-batch-prod"."init_spotify_album"
	where batch_id = '0'
),
artist AS (
	select id as artist_id,
		name AS artist_name,
		spotify_popularity as artist_popularity,
		genres as artist_genres
	FROM "platform-data-merging-batch-prod"."init_spotify_artist"
	where batch_id = '0'
),
label_artist as (
	select label,
		artist_id,
		ARBITRARY(artist_name) AS artist_name,
		ARBITRARY(artist_genres) AS artist_genres,
		MAX(artist_popularity) AS artist_popularity,
		ROW_NUMBER() OVER(
			partition by label
			ORDER BY MAX(artist_popularity) DESC
		) AS top
	from album
		cross join unnest(artists) AS ar(aa)
		JOIN artist ON (aa.id = artist_id)
	group by 1,
		2
),
label_genre AS (
	select label,
		genre,
		ROW_NUMBER() OVER(
			partition by label
			ORDER BY SUM(artist_popularity) DESC
		) AS top
	from label_artist
		cross join unnest(artist_genres) AS g(genre)
	group by 1,
		2
),
label_artists AS (
	select label,
		AVG(artist_popularity) AS avg_artist_popularity,
		approx_percentile(artist_popularity, 0.9) AS p90_artist_popularity,
		array_join(
			ARRAY_AGG(DISTINCT artist_name) FILTER (
				WHERE top < 10
			),
			', '
		) AS top_artists,
		COUNT(1) AS num_artists
	from label_artist
	GROUP BY 1
),
label_albums AS (
	select label,
		AVG(album_popularity) AS avg_album_popularity,
		approx_percentile(album_popularity, 0.9) AS p90_album_popularity,
		approx_percentile(album_popularity, 0.99) AS p99_album_popularity,
		array_join(
			ARRAY_AGG(DISTINCT album_name) FILTER (
				WHERE top < 10
			),
			', '
		) AS top_albums,
		COUNT(1) AS num_albums,
		SUM(num_tracks) AS num_tracks
	FROM album
	GROUP BY 1
),
label_genres AS (
	select label,
		array_join(
			ARRAY_AGG(DISTINCT genre) FILTER (
				WHERE top < 10
			),
			', '
		) AS top_genres,
		COUNT(1) AS num_genres
	from label_genre
	GROUP BY 1
)
select label,
	num_artists,
	num_albums,
	num_tracks,
	num_genres,
	avg_album_popularity,
	p90_album_popularity,
	p99_album_popularity,
	avg_artist_popularity,
	p90_artist_popularity,
	top_artists,
	top_albums,
	top_genres
from label_albums
	join label_artists USING(label)
	join label_genres USING(label)
order by 2 desc
limit 100