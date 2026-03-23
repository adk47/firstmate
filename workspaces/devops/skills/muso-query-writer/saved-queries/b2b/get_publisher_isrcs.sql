/*
id: get_publisher_isrcs
title: [B2B] Get Publisher isrcs
athena_id: 34040f05-ae0d-410f-b42e-d54341d12d58
primary_tag: b2b
tags: [b2b]
athena_database: platform-industry-mlc-bi-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select distinct isrc
from "platform-industry-mlc-bi-prod".workrightshares
	join "platform-industry-mlc-bi-prod".parties USING (feedproviderspartyid)
	join "platform-industry-mlc-bi-prod".works USING(feedprovidersworkid)
	join "platform-industry-mlc-bi-prod".worksrecordings USING(feedprovidersworkid)
	join "platform-industry-mlc-bi-prod".recordings USING(feedprovidersrecordingid)
where lower(partyrole) like '%publisher%'
and nullif(isrc, '') is not null
-- 	and fullname = 'ONE MUSIC ENTERTAINMENT PUBLISHING'
-- and ipinamenumber in ( 888742078, 638148432, 485019837)
-- and ipinamenumber in (861096526) -- Bolero Music
-- and ipinamenumber = 772780508 -- Bolero Music watchlist ( LOW WOOD PUBLISHING)
-- and ipinamenumber = 383996498 -- Bolero Music watchlist ( JOUUUE PUBLISHING)
and ipinamenumber in (478650121, 478650219) -- CODISCOS
