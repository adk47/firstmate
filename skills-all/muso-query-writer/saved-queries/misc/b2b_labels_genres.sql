/*
id: b2b_labels_genres
title: B2B - Labels Genres
athena_id: d053cdd8-452a-44b3-a617-3ded64507263
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
		IF(release_date > '2021-02-01', TRUE, FALSE) AS y2_released,
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
		CAST(
			ROW(
				primary_genre,
				primary_sub_genre,
				regional_genre,
				regional_sub_genre
			) AS ROW(
				primary_genre VARCHAR,
				primary_sub_genre VARCHAR,
				regional_genre VARCHAR,
				regional_sub_genre VARCHAR
			)
		) AS genre,
		ROW_NUMBER() OVER(
			partition by label
			ORDER BY SUM(artist_popularity) DESC
		) AS top
	from label_artist
		cross join unnest(artist_genres) AS g(genre)
		join postgresql_industry.public."catalog_industry_db_genres_mapping" ON (original = genre)
	group by 1,
		2
)
select genre.primary_genre AS "Primary Genre",
	genre.primary_sub_genre AS "Primary Sub Genre",
	genre.regional_genre AS "Regional Genre",
	genre.regional_sub_genre AS "Regional Sub Genre",
	count(1) AS num_labels
from label_genre
where top < 4
group by 1,
	2,
	3,
	4
order by 5 desc