/*
id: add_alb_log_partiton
title: Add ALB log partiton
athena_id: c89149d2-6ba1-47d0-978d-d9a2a6a8a402
primary_tag: misc
tags: [misc]
athena_database: aws_admin
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

ALTER TABLE alb_logs
ADD PARTITION (year = '2022', month = '10', day = '01') LOCATION 's3://logs-muso-3a38b95feee7ccb8/alb/production/AWSLogs/068358774785/elasticloadbalancing/us-west-2/2022/10/01/'