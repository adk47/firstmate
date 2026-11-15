SELECT lower(CAST(cr.id AS varchar)), CAST(cr.userid AS varchar), CAST(cr.createdat AS varchar),
 CAST(CASE WHEN cr.workspaceid IN (SELECT DISTINCT s.teamid FROM postgresql_core.public.subscriptions s WHERE s.status IN ('active','trialing')) THEN 1 ELSE 0 END AS varchar),
 CAST(CASE WHEN json_extract(cr.metadata, '$.proofRequest') IS NOT NULL THEN 1 ELSE 0 END AS varchar),
 coalesce(json_extract_scalar(cr.metadata, '$.proofRequest.noticeSentAt'), ''),
 CAST(CASE WHEN json_extract(cr.metadata, '$.freshDspCapture') IS NOT NULL THEN 1 ELSE 0 END AS varchar),
 coalesce(substr(json_format(json_extract(cr.metadata, '$.freshDspCapture')),1,200), ''),
 coalesce(json_extract_scalar(cr.metadata, '$.reviewStage'), ''),
 coalesce(array_join(map_keys(CAST(json_parse(json_format(cr.metadata)) AS map(varchar, json))), ';'), '')
FROM postgresql_core.public.credit_requests cr WHERE cr.status = 'user_verification_needed' AND cr.deletedat IS NULL
