date -u +%FT%TZ
stat -c '%y %s' /var/lib/hydra/credit-review/notify-tick/last-run.json
cat /var/lib/hydra/credit-review/notify-tick/last-run.json; echo
cat /var/lib/hydra/credit-review/notify-tick-status.txt
ls -la /etc/hydra/credit-notify-tick.disabled /etc/hydra/credit-decision-told.disabled 2>&1
