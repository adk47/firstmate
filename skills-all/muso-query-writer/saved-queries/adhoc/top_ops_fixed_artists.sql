/*
id: top_ops_fixed_artists
title: [adhoc] Top ops fixed artists
athena_id: 0d205d85-c1fc-4fbc-8f5c-b53a3fddfa53
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with tsa AS (
	select coalesce(
			try_cast(custom_data.popularity."$numberInt" as int),
			0
		) AS spotify_popularity,
		_id AS raw_profile_id
	from "platform-industry-db-industry-prod".raw_profile
	where not deleted.is_deleted
		and source = 'spotify'
)
select *
from (
		select _id as profile_id,
			ARBITRARY(name) AS name,
			MAX(spotify_popularity) AS spotify_popularity,
			MAX(
				coalesce(try_cast(popularity."$numberInt" as int), 0)
			) as popularity,
			MAX(
				coalesce(try_cast(credits_count."$numberInt" as int), 0)
			) as credits_count,
			ARBITRARY(common_credits) AS common_credits,
			ARBITRARY(size_group) AS size_group,
			ARBITRARY(country) AS country,
			ARBITRARY(legal_name) AS legal_name,
			concat('https://muso.ai/profile/', _id) AS muso_url
		from "platform-industry-db-industry-prod".catalog_profile
			cross join unnest(raw_profile_ids) AS cr(raw_profile_id)
			join tsa USING(raw_profile_id)
		where not deleted.is_deleted
			and not regexp_like(
				lower(name),
				'various|musik|music|nature|sound|relax|yoga|work|sleep|baby|orch|rain|medita|noise|ambien|focus|water|jazz|piano|violin|lounge|study|chill|storm|ocean|wind|stress|instrument|effect|nurs|weather|guitar|therapy|pregnan'
			)
			and profile_type in ('artist', 'professional')
			and (
				nullif(size_group, '') is not null
				or nullif(country, '') is not null
				or nullif(legal_name, '') is not null
			)
		group by 1
	)
order by spotify_popularity desc,
	popularity desc,
	credits_count desc
limit 5000