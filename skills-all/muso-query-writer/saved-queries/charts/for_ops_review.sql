/*
id: for_ops_review
title: [charts] For Ops Review
athena_id: 1d7a18fb-efcb-4755-badd-dba7baa5b9cc
primary_tag: charts
tags: [charts]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with p AS (
	select _id AS profile_id,
		profile_type,
		try(images [ 1 ].url) AS avatar_url,
		name
	from hive."platform-industry-bi-prod".matvw_catalog_profile
	where profile_type in ('artist', 'professional')
		and not regexp_like(
			lower(name),
			'various|musik|music|nature|sound|relax|yoga|work|sleep|baby|orch|rain|medita|noise|ambien|focus|water|jazz|piano|violin|lounge|study|chill|storm|ocean|wind|stress|instrument|effect|nurs|weather|guitar|therapy|pregnan'
		)
		and not is_deleted
),
rising AS (
	with s as (
		select profile_id,
			arbitrary(p.profile_type) AS profile_type,
			max_by(overall_score, date) AS cur_score,
			min(overall_score) AS prev_score
		from "platform-industry-calc-prod"."calc_credit_score_history"
			join p using(profile_id)
		where date in (
				select date
				from "platform-industry-calc-prod"."calc_credit_score_history$partitions"
				order by date desc
				limit 10
			)
		group by 1
		having count(1) > 1
	)
	select profile_id,
		cur_score - prev_score AS score_diff,
		rising_diff_rank
	from (
			select profile_id,
				profile_type,
				ROW_NUMBER() over (
					partition by profile_type
					order by cur_score - prev_score desc
				) AS rising_diff_rank,
				cur_score,
				prev_score
			from s
			where cur_score - prev_score > 0
		)
	where rising_diff_rank <= 100
),
c AS (
	select coalesce(MIN_BY(category, position), 'overall') AS category,
		profile_id,
		ARBITRARY(p.profile_type) AS type,
		ARBITRARY(p.name) AS name,
		ARBITRARY(p.avatar_url) AS "avatar_url",
		MIN(position) AS position,
		MIN_BY(position_change, position) AS position_change,
		MIN_BY(score, position) AS score,
		MIN_BY(score_change, position) AS score_change,
		MIN_BY(credits_count, position) AS "credits_count",
		MIN_BY(credits_count_change, position) AS "credits_count_change",
		MIN_BY(date, position) AS "date"
	from (
			select *
			from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
			where date in (
					select max(date)
					from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
				)
		) AS charts
		full outer join rising USING(profile_id)
		join p USING(profile_id)
	where rising_diff_rank <= 100
		or (
			date in (
				select max(date)
				from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
			)
			and (
				(
					category not in (
						'Artist',
						'Engineer',
						'Assistant Engineer'
					)
					and position <= 105
				)
			)
		)
	group by profile_id
)
select c.*
from hive."platform-industry-bi-prod".matvw_catalog_profile AS p
	right join c ON (profile_id = p._id)
where p.images is null
	or cardinality(p.images) = 0
	or nullif(p.legal_name, '') is null
order by if(avatar_url is NULL, 0, 1),
	if(category like 'Music%', 1, 0),
	position