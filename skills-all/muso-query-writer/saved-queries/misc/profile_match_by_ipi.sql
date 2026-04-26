/*
id: profile_match_by_ipi
title: [TikTok] Profile match by IPI
athena_id: 4bad4902-b389-4d03-af65-ca28c1b07c8c
primary_tag: tiktok
tags: [tiktok]
trino_catalog: hive
trino_schema: mlc
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with mlc as (
    select 
        'mlc:'|| cast(feedproviderspartyid as varchar) as rid, 
        ipinamenumber
    from hive.mlc.parties 
    where ipinamenumber in (
        2852023,
21007060,
29756257,
45656272,
48372371,
49716665,
88721248,
125050617,
125457187,
135186578,
185580443,
214251707,
241219010,
276904044,
284624546,
287735320,
291821850,
295393229,
335994328,
343948929,
344151980,
346139168,
348784121,
360778049,
363622662,
364655439,
365379820,
371424769,
393819810,
403302716,
407543666,
409898114,
413662085,
421223218,
423764067,
433323883,
434791541,
444411483,
448866995,
449801927,
465167244,
476010963,
479118426,
479180618,
479363313,
482580437,
497906397,
500841887,
505386851,
518986208,
520239099,
521231016,
525772147,
537436147,
544829525,
560068268,
561855823,
569826493,
572800453,
576262919,
583831229,
591992891,
604067379,
606483351,
609389026,
615851446,
621786245,
635452939,
636544730,
637303655,
639404145,
641400198,
645766313,
648213251,
649447603,
650164960,
650171377,
658524124,
661010788,
668590101,
672816619,
680363050,
690952510,
696304322,
696995354,
712781743,
717526634,
730662261,
740359938,
762170745,
767306323,
767695376,
777879943,
781228924,
784977563,
789327387,
793475299,
809608422,
818233346,
818782304,
844763410,
846383606,
854148034,
855408911,
860526241,
863987865,
871411252,
875760885,
895091499,
1053757162,
1061359279,
1066546448,
1128045582,
1138125186,
1143106800,
1158012680,
1175379526,
552384252,
629244000,
569476493,
667960984,
590724436,
598834382,
62502506,
61989442
    )
),
r as (
    select distinct
        seatid as _id,
        TRUE as in_roster,
        count_if(status = 'active') > 0 as is_paid
    from postgresql_core.public.public_roster_seats 
    group by 1 
),
c as (
    select distinct
        profileid as _id,
        TRUE as is_claimed
    from postgresql_core.public.public_claiming 
    where status = 'processed'
)
select 
    ipinamenumber as ipi,
    name,
    credits_count,
    coalesce(in_roster, FALSE) as in_roster,
    coalesce(is_claimed, FALSE) as is_claimed,
    coalesce(is_paid, FALSE) as is_paid,
    'https://credits.muso.ai/profile/'||_id as muso_url
from hive.default.matvw_catalog_profile
cross join unnest(raw_profile_ids) as pr(rid)
join mlc USING(rid)
left join r USING(_id)
left join c USING(_id)
where not is_deleted 