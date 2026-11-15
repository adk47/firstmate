echo "=====GREP gate in live path"
grep -n -i 'copy_gate\|outbound_copy\|gate\.py\|sendgate' /opt/hydra/scripts/credit-notify-tick.py /opt/hydra/scripts/credit-decision-told.py /opt/hydra/scripts/credit_review/decision_told.py /opt/hydra/scripts/credit_review/notify_chunks.py /opt/hydra/scripts/credit_review/notify_tick.py /root/mklist2.js; echo "grep rc=$?"
echo "=====GATE REPORT"
cd /opt/hydra && timeout 60 python3 scripts/outbound_copy/gate.py report 2>&1 | head -c 6000; echo; echo "report rc=$?"
echo "=====GATE MODE"
timeout 20 python3 scripts/outbound_copy/gate.py mode decision-approved 2>&1 | head -3
echo "=====LIVE decision_told.py"
cat /opt/hydra/scripts/credit_review/decision_told.py
echo "=====MKLIST"
cat /root/mklist2.js
