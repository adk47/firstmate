/*
id: spotify_export
title: Spotify Export
athena_id: 67fe86d1-a9de-477a-ad66-03f7807b1880
primary_tag: misc
tags: [misc]
athena_database: adhoc_spotify_isrcs
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with skip_profiles AS (
	select
	profile_id, 
	profile_id AS id,
	TRUE AS remove
	from (
			select array [
			'6ab2dbcb-17c7-4822-a9a3-68def236c73a' -- Traditional
			,'d5480d71-c204-4a45-8265-b3719ccc9095' -- Various Artists
			,'ad0133a8-a11b-4580-8ab1-a2b028114e3d' -- Anonymous
			,'45f5fd56-5d26-412a-8e4d-52fc362ac758' -- Unknown
			,'4a2f36e9-1c9e-49d9-a572-2444e7ed9308' -- Universal Music
			,'06209837-acfe-4596-9be4-1ebb1e3b51d2' -- Universal
			] AS profile_ids
		) cross join unnest(profile_ids) AS p(profile_id)
)
-- select * from output_isrc
-- profile
-- select profile_id, o.* from output_profile AS o
-- left join skip_profiles as ps USING(profile_id)
-- where ps.remove is null
-- credit
-- select distinct profile_id, o.* from "output_credit" as o
-- left join skip_profiles AS ps using(profile_id)
-- where ps.remove is null and cardinality(track_spotify_ids) > 0
-- limit 10000
-- collab
select distinct o.* from "output_collaborator" as o
left join skip_profiles as ps on(o.profile_id=ps.id)
left join skip_profiles as cs ON(o.collaborator_id=cs.id)
where ps.remove is null and cs.remove is null and o.profile_id in (
    select distinct profile_id from "output_credit" as o
where cardinality(track_spotify_ids) > 0
)
-- limit 10000