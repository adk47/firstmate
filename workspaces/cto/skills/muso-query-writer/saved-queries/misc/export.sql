/*
id: export
title: [Zyte] Export
athena_id: 6f61bba5-6bcc-4462-948b-cf754da14076
primary_tag: zyte
tags: [zyte]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

drop table if exists `sandbox-oleg`.track_instagram_link

CREATE TABLE "sandbox-oleg"."track_instagram_link" WITH (
	external_location = 's3://databaseslake/sandbox-oleg/track_instagram_link/v2/'
) AS
select distinct
    src.sourceUrl AS source_link,
    trackid as track_id,
    createdat as created_at,
    updatedat as updated_at,
    src.external_id as external_id
from "platform-core-backend-export-prod-last-with-songstats"."public_track_activities"
            cross join unnest(
                CAST(
                    json_extract(links, '$') AS ARRAY(
                        ROW(
                            sourceUrl varchar,
                            source varchar,
                            external_id varchar
                        )
                    )
                )
            ) AS l(src)
where src.source = 'instagram'

select 
    distinct replace(source_link, 'https://www.instagram.com/reels/audio/', '') as ig_audio_id
from  "sandbox-oleg"."track_instagram_link"

select 
    distinct IF(c.value like '%http%' or c.value like '%://%', c.value, 'https://www.instagram.com/'||c.value) 
    as ig_profile_link
from "platform-industry-db-industry-dev".catalog_profile
cross join unnest(contacts) as con(c)
where c.type ='instagram'


select 
    *
                from (
                    select distinct
                        src.sourceUrl AS source_link
                    from "platform-core-backend-export-prod-last-with-songstats"."public_track_activities"
                                cross join unnest(
                                    CAST(
                                        json_extract(links, '$') AS ARRAY(
                                            ROW(
                                                sourceUrl varchar,
                                                source varchar,
                                                external_id varchar
                                            )
                                        )
                                    )
                                ) AS l(src)
                    where src.source = 'instagram'
                ) 
                ORDER BY RANDOM()
                LIMIT 1000