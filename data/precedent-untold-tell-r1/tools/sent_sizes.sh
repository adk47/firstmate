# Read-only: how many credits the largest confirmed notices carried, and when the 413s happened.
date -u +%FT%TZ
python3 - <<'P'
import sqlite3
db = sqlite3.connect("file:/var/lib/hydra/credit-review/ledger.sqlite3?mode=ro", uri=True, timeout=30)
print("largest_sent (subjects, at, user)")
for r in db.execute("SELECT json_array_length(subject_ids_json), at, user_id FROM decision_told WHERE mode='apply' "
                    "AND outcome='sent' ORDER BY 1 DESC LIMIT 12"):
    print(" ", r)
print("413 errors (subjects, at, user)")
for r in db.execute("SELECT json_array_length(subject_ids_json), at, user_id FROM decision_told WHERE mode='apply' "
                    "AND outcome='error' AND report_json LIKE '%(413)%' ORDER BY at"):
    print(" ", r)
print("attempt-only or error rows with 150+ subjects (subjects, at, user, outcome)")
for r in db.execute("SELECT json_array_length(subject_ids_json), at, user_id, outcome FROM decision_told WHERE "
                    "mode='apply' AND outcome<>'sent' AND json_array_length(subject_ids_json) >= 150 ORDER BY at"):
    print(" ", r)
P
