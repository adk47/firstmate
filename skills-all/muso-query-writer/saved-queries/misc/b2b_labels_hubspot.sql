/*
id: b2b_labels_hubspot
title: B2B - Labels HubSpot
athena_id: 38bd5582-50f6-4da4-8c51-94ffbb4f53d4
primary_tag: misc
tags: [misc]
athena_database: platform-data-merging-batch-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with album AS (
	select custom_data.label,
		source_release_id AS album_id,
		name as album_name,
		custom_data.popularity."$numberInt" AS album_popularity,
		CARDINALITY(recordings) AS num_tracks,
		IF(release_date > '2022-02-01', TRUE, FALSE) AS recently_released,
		artists,
		ROW_NUMBER() OVER(
			partition by label
			ORDER BY popularity DESC
		) AS top
	from hive.default."matvw_raw_release"
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
	from postgresql_industry.public."catalog_industry_db_genres_mapping"
),
label_genre AS (
	select label,
		muso_genre AS genre,
		ROW_NUMBER() OVER(
			partition by label
			ORDER BY SUM(artist_popularity) DESC
		) AS top
	from label_artist
		cross join unnest(artist_genres) AS g(genre)
		join muso_genre ON (lower(genre) = original)
	group by 1,
		2
),
label_artists AS (
	select label,
		AVG(artist_popularity) AS avg_artist_popularity,
		approx_percentile(artist_popularity, 0.9) AS p90_artist_popularity,'<ol>' || array_join(
			transform(
				array_sort(
					ARRAY_AGG(
						CAST(
							ROW(artist_html, artist_popularity) AS ROW(html varchar, popularity double)
						)
					) FILTER (
						WHERE top < 101
					),
					(x, y)->CASE
						WHEN x.popularity IS NULL THEN 1
						WHEN y.popularity IS NULL THEN -1
						WHEN x.popularity < y.popularity THEN 1
						WHEN x.popularity = y.popularity THEN 0 ELSE -1
					END
				),
				a->a.html
			),
			'<br>'
		) || '</ol>' AS top_artists,
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
		COUNT_IF(recently_released) AS num_albums_last_year,
		SUM(num_tracks) AS num_tracks
	FROM album
	GROUP BY 1
),
label_genres AS (
	select label,
		ARRAY_AGG(DISTINCT genre) FILTER (
			WHERE top < 4
		) AS top_genres,
		COUNT(1) AS num_genres
	from label_genre
	GROUP BY 1
)
select to_hex(md5(to_utf8(label))) AS "Record ID",
	label AS "Name",
	num_artists AS "Roster Size",
	num_tracks AS "Catalog Size",
	p90_artist_popularity AS "Artist Popularlity",
	num_albums_last_year AS "Releases Last 12months",
	ARRAY_JOIN(
		array_distinct(
			TRANSFORM(
				FILTER(top_genres, f->f.primary_genre IS NOT NULL),
				a->a.primary_genre
			)
		),
		';'
	) AS "Primary Genre",
	ARRAY_JOIN(
		array_distinct(
			TRANSFORM(
				FILTER(top_genres, f->f.primary_sub_genre IS NOT NULL),
				a->a.primary_sub_genre
			)
		),
		';'
	) AS "Sub-Genre",
	ARRAY_JOIN(
		array_distinct(
			TRANSFORM(
				FILTER(top_genres, f->f.regional_genre IS NOT NULL),
				a->a.regional_genre
			)
		),
		';'
	) AS "Regional Genre",
	ARRAY_JOIN(
		array_distinct(
			TRANSFORM(
				FILTER(top_genres, f->f.regional_sub_genre IS NOT NULL),
				a->a.regional_sub_genre
			)
		),
		';'
	) AS "Regional Sub-Genre",
	'Label' AS "Type",
	top_artists AS "Note"
from label_albums
	join label_artists USING(label)
	left join label_genres USING(label)
order by 1


select count(1) from "init_spotify_artist" where cardinality(genres) > 0