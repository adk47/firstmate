/*
id: find_profile_mlc_ids_through_songwriter_tracks
title: [Audit] Find profile MLC IDs through songwriter tracks
athena_id: 8bb372ed-dfce-47c5-8809-1eb099fdc8f7
primary_tag: audit
tags: [audit]
athena_database: platform-industry-mlc-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with m as (
	select substr(rid, 5) as feedprovidersrecordingid
	from "platform-industry-bi-prod".matvw_catalog_track
		cross join unnest(raw_recording_ids) as r(rid)
	where not is_deleted
		and cardinality(
			filter(
				profiles,
				p->p.profile_id = 'dd329281-c695-4866-8908-c72e77fd8dee'
				and cardinality(
					filter(
						p.catalog_credits,
						c->c.parent = 'Songwriter'
					)
				) > 0
			)
		) > 0
		and rid like 'mlc:%'
)
select feedproviderspartyid,
	min(ipinamenumber) as ipi,
	min(fullname) as fullname,
	count(distinct feedprovidersworkid) as num_works,
	count(1) as num_contributions
from "platform-industry-mlc-bi-prod".workrightshares as ws
	join "platform-industry-mlc-bi-prod".worksrecordings as w USING(feedprovidersworkid)
	join "platform-industry-mlc-bi-prod".parties as p USING(feedproviderspartyid)
	join m USING(feedprovidersrecordingid)
where partyrole in (
		'ComposerLyricist',
		'Composer',
		'Lyricist'
	)
group by 1
order by 4 desc, 5 desc