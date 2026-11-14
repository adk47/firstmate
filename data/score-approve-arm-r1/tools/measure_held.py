#!/usr/bin/env python3
"""The rows score-approve would NOT approve, grouped by the job's own reason (read-only).

Input is the dry run's decision log (score-approve-dryrun-r1 `out.jsonl`: one `cohort` line per selected
request, one `row` line per decision the deployed job made on it, one `gate` line per account). That file
carries customer names and e-mail addresses inside the re-read rows, so it is NOT committed; this tool reads
it where it lies and prints ids-free counts.

    measure_held.py OUT_JSONL                      the groups, with and without the green-band rule
    measure_held.py OUT_JSONL --stage2-ids         {"requests": {...}} of the engaged rows, for stage2_read.py
    measure_held.py OUT_JSONL --stage2 FILE        the engaged rows split by the stage-2 verdict in FILE
    measure_held.py OUT_JSONL --scope-ids          {request id: [user id, createdAt]}, for proof_scope_read.py
    measure_held.py OUT_JSONL --stage2 S --scope P --decider D
                                                   the proof-on-file rows by: does a filed document name the
                                                   request, does the decider hold it for stage 2, the verdict

S, P and D are the stdout of stage2_read.py, proof_scope_read.py and decider_state_read.py (run on node-8,
read-only). They carry request and user ids, so they are not committed either.
"""
import collections
import json
import sys


def load(path):
    rows, dec, gate = {}, {}, {}
    for line in open(path, encoding="utf-8"):
        o = json.loads(line)
        if o["k"] == "cohort":
            rows[o["id"]] = o
        elif o["k"] == "row":
            dec[o["id"]] = o          # a later pass wins
        elif o["k"] == "gate":
            gate[str(o["user"])] = o
    return rows, dec, gate


def reason_class(d):
    if d["decision"] == "approve":
        return "approve"
    why = d["reason"].replace("score approval not now: ", "")
    if why.startswith("proof path: engaged user ("):
        return why.split("):")[0] + ")"
    return why.split(" (")[0].split(":")[0][:70]


def not_green(g):
    """account_gate.watch_refusal on the gate's own answer: an allow that is not a measured green."""
    band = g.get("band")
    return g["decision"] == "allow" and (band != "green" or bool((g.get("extra") or {}).get("watch")))


def main():
    path = sys.argv[1]
    rows, dec, gate = load(path)
    user = lambda i: str(rows[i]["user"])
    if "--scope-ids" in sys.argv:
        print(json.dumps({i: [user(i), rows[i].get("created")] for i, d in dec.items()
                          if reason_class(d).startswith("proof path")}))
        return
    if "--stage2-ids" in sys.argv:
        print(json.dumps({"requests": {i: user(i) for i, d in dec.items()
                                       if reason_class(d).startswith("proof path")}}))
        return
    groups = collections.defaultdict(list)
    for i, d in dec.items():
        groups[(d["decision"], reason_class(d))].append(i)
    print(f"cohort {len(rows)} rows / {len({user(i) for i in rows})} users; decided {len(dec)}")
    for (decision, cls), ids in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        bands = collections.Counter(f"{gate[user(i)]['decision']}/{gate[user(i)]['band']}" for i in ids)
        print(f"{len(ids):5d} rows {len({user(i) for i in ids}):4d} users  {decision:7s} {cls}  "
              f"| paid rows {sum(1 for i in ids if dec[i].get('paid'))} | gate {dict(sorted(bands.items()))}")
    approve = groups[("approve", "approve")]
    out = [i for i in approve if not_green(gate[user(i)])]
    print(f"green-band rule: {len(out)} rows / {len({user(i) for i in out})} users of the {len(approve)} leave the "
          f"approve set; {len(approve) - len(out)} rows / {len({user(i) for i in approve} - {user(i) for i in out})} "
          f"users stay; not approved in all: {len(dec) - len(approve) + len(out)}")
    if "--stage2" in sys.argv:
        s2 = json.load(open(sys.argv[sys.argv.index("--stage2") + 1]))
        by = collections.defaultdict(list)
        for i, v in s2["requests"].items():
            key = "account held by stage 2 (reject_hold / account hold)" if v["account_held"] else v["outcome"]
            by[key].append(i)
        print(f"stage 2 (analyzer {s2['analyzer_version']}), {len(s2['requests'])} engaged rows:")
        for key, ids in sorted(by.items(), key=lambda kv: -len(kv[1])):
            mix = collections.Counter("+".join(s2["requests"][i]["roles"]) for i in ids) if key == "mixed" else {}
            print(f"{len(ids):5d} rows {len({user(i) for i in ids}):4d} users  {key}  "
                  f"| paid rows {sum(1 for i in ids if dec[i].get('paid'))}"
                  + (f" | {dict(mix.most_common(6))}" if mix else ""))
    if "--scope" in sys.argv and "--decider" in sys.argv and "--stage2" in sys.argv:
        scope = json.load(open(sys.argv[sys.argv.index("--scope") + 1]))
        state = json.load(open(sys.argv[sys.argv.index("--decider") + 1]))["requests"]
        by = collections.defaultdict(list)
        for i, d in dec.items():
            if reason_class(d) != "proof path: engaged user (proof on file)":
                continue
            named = scope["requests"][i]["class"].startswith("this_request")
            row = state[i.lower()]["decider"]
            if not row:
                held = "no decider row: stage 2 cannot see it yet"
            elif row["decision"] == "hold" and row["reason_class"] == "proof on file":
                held = "decider holds it as proof on file: stage 2's input"
            else:
                held = "another decider row (defer / support): not stage 2's input"
            by[("a filed document names this request" if named else "the ACCOUNT has proof on file, no document "
                "names this request", held, s2["requests"][i]["outcome"])].append(i)
        print(f"proof on file (export of {scope['export_generated_at']}), by document scope / decider / stage 2:")
        for key, ids in sorted(by.items(), key=lambda kv: (kv[0][0], -len(kv[1]))):
            print(f"{len(ids):5d} rows {len({user(i) for i in ids}):4d} users  {' | '.join(key)}  "
                  f"| paid rows {sum(1 for i in ids if dec[i].get('paid'))}")


if __name__ == "__main__":
    main()
