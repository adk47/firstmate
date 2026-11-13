import json, statistics, subprocess
from datetime import datetime
def api(path):
    return json.loads(subprocess.run(['gh', 'api', f'repos/Muso-AI/hydra/{path}'], capture_output=True, text=True, check=True).stdout)
def ts(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))
# pr: (kind, suite run, the run whose green `validate` unblocked it)
rows = {1936: ('stale-mirror', 43387660492, 43388110812), 1927: ('stale-mirror', 43372219982, 43372232929),
        1886: ('stale-mirror', 43024617314, 43025286085), 1863: ('legacy-expected', 42507945805, 43424609651),
        1856: ('legacy-expected', 42455765843, 43424769234), 1855: ('legacy-expected', 42466151169, 43424774951)}
out, held, act = [], [], []
for pr, (kind, suite, fix) in rows.items():
    sj = [j for j in api(f'actions/runs/{suite}/jobs?per_page=100')['jobs'] if j['name'] in ('validate-code', 'validate')]
    # the suite's own verdict job: validate-code after the split, validate before it
    j = next((x for x in sj if x['name'] == 'validate-code'), None) or next(x for x in sj if x['name'] == 'validate')
    green = ts(j['completed_at'])
    fj = [x for x in api(f'actions/runs/{fix}/jobs?per_page=100')['jobs'] if x['name'] == 'validate'][-1]
    start, done = ts(fj['started_at']), ts(fj['completed_at'])
    h = (done - green).total_seconds() / 3600
    held.append(h); act.append((done - start).total_seconds())
    out.append({'pr': pr, 'kind': kind, 'suite_run': suite, 'suite_green_at': j['completed_at'], 'suite_job': j['name'], 'suite_conclusion': j['conclusion'],
                'fix_run': fix, 'fix_job_started': fj['started_at'], 'fix_job_completed': fj['completed_at'], 'fix_conclusion': fj['conclusion'],
                'held_hours': round(h, 2), 'fix_job_seconds': (done - start).total_seconds()})
    print(f"#{pr} {kind:15} suite {j['name']}={j['conclusion']} at {j['completed_at']} -> validate={fj['conclusion']} at {fj['completed_at']}  held {h:8.2f} h  mirror job {(done-start).total_seconds():.0f} s")
print('held hours  median', round(statistics.median(held), 2), 'min', round(min(held), 2), 'max', round(max(held), 2))
print('mirror job seconds  median', statistics.median(act), 'max', max(act))
json.dump(out, open('/tmp/vcs/durations.json', 'w'), indent=1)
