/*
id: netflix_xml_files
title: [ERN] Netflix xml files
athena_id: bf6faed2-54cb-4038-92e1-5c5d67cbcaa4
primary_tag: ern
tags: [ern]
athena_database: platform-netflix-testdev
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

SELECT res.soundrecordingid.isrc,
	res.referencetitle.titletext,
	transform(
		res."SoundRecordingDetailsByTerritory".DisplayArtist,
		a->cast(
			row(a.artistrole, a.partyname.fullname) as row(
				role varchar,
				name varchar
			)
		)
	) AS artists,
	transform(
		res."SoundRecordingDetailsByTerritory".indirectresourcecontributor,
		a->cast(
			row(a.indirectresourcecontributorrole, a.partyname.fullname) as row(
				roles array(varchar),
				name varchar
			)
		)
	) AS credits,
	res."SoundRecordingDetailsByTerritory".Genre,
	res."SoundRecordingDetailsByTerritory".LabelName
FROM "platform-netflix-testdev"."test_netflix_json"
	cross join unnest("resourcelist"."SoundRecording") AS rl(res)