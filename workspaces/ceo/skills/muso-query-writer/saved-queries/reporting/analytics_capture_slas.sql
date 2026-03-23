/*
id: analytics_capture_slas
title: [reporting] Analytics Capture SLAs
athena_id: c8240664-ebc1-4e30-ada7-0ec1194c7cbd
primary_tag: reporting
tags: [reporting]
athena_database: platform-industry-calc-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

select
    source,
    num_ids,
    num_1d_sla,
    num_1w_sla,
    num_1m_sla,
    100 * num_1d_sla / num_ids AS pct_1d_sla,
    100 * num_1w_sla / num_ids AS pct_7d_sla,
    100 * num_1m_sla / num_ids AS pct_1m_sla
from (
		select source,
			sum(num_ids) AS num_ids,
			sum(if(num_days < 2, num_ids, 0)) AS num_1d_sla,
			sum(if(num_days < 8, num_ids, 0)) AS num_1w_sla,
			sum(if(num_days < 32, num_ids, 0)) AS num_1m_sla
		from (
				select source,
					date_diff('day', date(last_captured_date), current_date) AS num_days,
					count(1) AS num_ids
				from (
						select source,
							id,
							max(capture_date) as last_captured_date
						from "platform-industry-calc-prod".calc_analytics_history
						where capture_date >= '2024-05-01'
						group by 1,
							2
					)
				group by 1,
					2
			)
		group by 1
	)