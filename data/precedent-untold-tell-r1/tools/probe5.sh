date -u +%FT%TZ
systemctl show credit-notify-tick.timer -p NextElapseUSecRealtime -p LastTriggerUSec 2>/dev/null
systemctl is-active credit-notify-tick.service
cat <<'SQL' | timeout 240 /opt/hydra/scripts/trino-query.sh 2>/dev/null | grep '^"'
SELECT CAST(userid AS varchar), lower(CAST(id AS varchar)), status, CAST(workspaceid AS varchar), CAST(profileid AS varchar), coalesce(json_extract_scalar(metadata, '$.approvedNotice.noticeSentAt'), ''), coalesce(json_extract_scalar(metadata, '$.decisionNotice.noticeSentAt'), ''), CAST(updatedat AS varchar), coalesce(substr(json_format(json_extract(metadata, '$.decisionNotice')), 1, 400), ''), coalesce(substr(json_format(json_extract(metadata, '$.approvedNotice')), 1, 400), '') FROM postgresql_core.public.credit_requests WHERE userid IN (6678,17097,19104,19327,22104,26504,27448,27927,29419,32439,50621,53479,56521,61588,63778,68272,70317,72407,75714,77481,78042,84189,91567,96293,96558,99416,100814,102783,109550,109681,119162,119526,153177,155423,212494,230556,233234,243908,252460,255205,270441,275342,279975,288257,291623,304550,305363,319572,325208,336111,347304,368676,368924) AND deletedat IS NULL AND json_extract_scalar(metadata, '$.approval.via') = 'precedent_v1' ORDER BY 1,2
SQL
echo "rc=${PIPESTATUS[1]}"; date -u +%FT%TZ
