/*
id: genre_category_top_export
title: Genre category top export
athena_id: 6789c51c-b9c2-42a0-b007-1ee942dff08e
primary_tag: misc
tags: [misc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select genre,
	category,
	rank,
	name,
	popularity,
	'https://credits.muso.ai/profile/' || profile_id as muso_url,
	'https://credits.muso.ai/track/' || top_track_id as top_track_url,
	top_original_genres
	,profile_id
	,common_credits
	,roles
	,image_url
from (
    select
        profile_id,
        genre,
        category,
		row_number() over (
			partition by genre,
			category
			order by sum_popularity desc
		) as rank,
		popularity,
		name,
		top_track_id,
		top_original_genres,
		common_credits,
		roles,
		profile_type,
		images[1].url as image_url
    from (
		select profile_id,
			genre,
			category,
			SUM(popularity) as sum_popularity,
			max_by(track_id, popularity) as top_track_id,
			max_by(original_genres, popularity) as top_original_genres
		from (
				select profile_id,
					genre,
					category,
					track_id,
					popularity,
					original_genres,
					row_number() over (
						partition by profile_id,
						genre,
						category
						order by popularity desc
					) as track_num
				from (
						select profile.profile_id as profile_id,
							track_genre as genre,
							case
								when catalog_credit.child = 'Publisher' then 'Publisher'
								when catalog_credit.child = 'Record Label' then 'Record Label'
								when catalog_credit.child = 'Studio' then 'Studio'
								when catalog_credit.parent = 'Artist' then 'Artist'
								when catalog_credit.parent like '%Producer%' then 'Producer'
								when catalog_credit.parent = 'Songwriter' then 'Songwriter'
								when catalog_credit.parent = 'Musician' then 'Musician'
								when catalog_credit.parent = 'Engineer' then 'Engineer'
							end as category,
							track_id,
							max(popularity) as popularity,
							arbitrary(original_genres) as original_genres
						from (
								select t._id as track_id,
									catalog_genre.primary_sub_genre as track_genre,
									MAX(coalesce(t.popularity, 0)) as popularity,
									array_agg(distinct genre) as original_genres,
									arbitrary(profiles) as profiles
								from hive."platform-industry-bi-prod".matvw_catalog_track as t
								    join hive."platform-industry-bi-prod".matvw_raw_recording as r ON (default_raw_recording_id=r._id)
									cross join unnest(artist_ids) as tp(artist_id)
									join hive."platform-industry-bi-prod".matvw_raw_profile as rp ON(artist_id = rp._id)
									cross join unnest(genres) as rpg(genre)
									join hive."platform-industry-bi-prod".matvw_dict_genre as g ON (g._id = genre)
									cross join unnest(catalog_genres) as cg(catalog_genre)
								where not r.is_deleted
									and not t.is_deleted
									and not rp.is_deleted
									and coalesce(catalog_genre.regional_genre, '') <> 'India'
								group by 1,
									2
							)
							cross join unnest(profiles) as p(profile)
							cross join unnest(profile.catalog_credits) as p(catalog_credit)
						group by 1,
							2,
							3,
							4
					)
				where category is not null
			)
		where track_num <= 100
		group by 1,
			2,
			3
	) as c
	join hive."platform-industry-bi-prod".matvw_catalog_profile as p ON (p._id = profile_id)
	where 
	    not p.is_deleted 
	    and TRY(images[1].url) is not null 
	    and profile_type in ('artist', 'professional', 'organization')
)
where rank < 51
order by 1,
	2,
	3