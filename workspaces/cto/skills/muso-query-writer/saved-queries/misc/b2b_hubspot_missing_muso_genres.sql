/*
id: b2b_hubspot_missing_muso_genres
title: B2B - HubSpot - Missing Muso Genres
athena_id: a2b48d28-e12c-4c62-97ea-17b39a350b80
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
		'<li><a href="https://open.spotify.com/artist/' || artist_id || '">' || ARBITRARY(artist_name) || '</a> (' || CAST(
			MAX(CAST(ceiling(artist_popularity) AS int)) AS varchar
		) || ') </li>' AS artist_html,
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
muso_genre AS (
	select distinct lower(original) AS original,
		cast(
			ROW(
				lower(primary_genre),
				lower(primary_sub_genre),
				lower(regional_genre),
				lower(regional_sub_genre)
			) AS ROW(
				primary_genre VARCHAR,
				primary_sub_genre VARCHAR,
				regional_genre VARCHAR,
				regional_sub_genre VARCHAR
			)
		) AS muso_genre
	from "platform-data-merging-catalog-prod"."catalog_industry_db_genres_mapping"
)
select lower(genre) AS missing_mapping_genre,
	count(distinct label) AS num_labels
from label_artist
	cross join unnest(artist_genres) AS g(genre)
	LEFT join muso_genre ON (lower(genre) = original)
where muso_genre IS NULL
group by 1
order by 2 desc