"""The daily reversible-hide batch: one H-DevOps PR (HIDDEN_ENTITY_IDS, prod + dev -> 410 + noindex) and one
platform-data-processing PR (sitemap LEGAL_HIDDEN_ENTITY_IDS + its strict-equality test), generated from PASS rows.
Shape follows H-DevOps #4619 + PDP #2574 (Arpad, cs-systemic-c3).

The pipeline never hides by itself (captain standing order, c3 handoff §4.1): it PREPARES the PRs; a person
merges them, and only the 410 read-back (checks.public_gone) ever writes `hidden_at`. Nothing is deleted; there
is no `DELETE /api/v3/admin/profile` and no muso-cli delete anywhere in this module. Undo = remove the id.

Editors are pure (text in, text out) and refuse rather than guess when a file's shape is not the expected one.
Ids only in files and PR text: no requester names (the legal_hidden list says "Ids only; no names").
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from gdpr_pipeline.sources import (HDEVOPS_FILES, HDEVOPS_REPO, PDP_LIST, PDP_REPO, PDP_TEST, UUID_RE,
                                   Unknown, hidden_ids_from_yaml, legal_hidden_from_py)


# The commit identity of the batch PRs (the gh account that opens them); overridable per host.
GIT_NAME = os.environ.get("GDPR_GIT_NAME", "hydra gdpr-pipeline")
GIT_EMAIL = os.environ.get("GDPR_GIT_EMAIL", "5307497+adk47@users.noreply.github.com")


UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
# The two shapes an ADDED hide-list line takes:
#   PDP       `"<uuid>": ("profile", "gdpr-erasure-register-12"),`
#   H-DevOps  `value: "<uuid>,<uuid>,..."`   (HIDDEN_ENTITY_IDS is ONE comma-joined string in the manifest)
DICT_ENTRY_RE = re.compile(r'^\s*"' + UUID_RE.pattern + r'"\s*:')
YAML_VALUE_RE = re.compile(r'^\s*(?:-\s*)?value:\s*["\']?([^"\'\n]*)')

class ShapeError(RuntimeError):
    pass


def add_to_hidden_yaml(text: str, ids: list[str], comment: list[str]) -> tuple[str, list[str]]:
    m = re.search(r"^(?P<ind>[ \t]*)- name: HIDDEN_ENTITY_IDS\n(?P<vind>[ \t]*)value: \"(?P<val>[^\"]*)\"\n",
                  text, re.M)
    if not m or text.count("name: HIDDEN_ENTITY_IDS") != 1:
        raise ShapeError("expected exactly one HIDDEN_ENTITY_IDS env entry")
    have = [x.strip() for x in m.group("val").split(",") if x.strip()]
    add = [i for i in ids if i not in have]
    if not add:
        return text, []
    ind, vind = m.group("ind"), m.group("vind")
    block = "".join(f"{ind}# {c}\n" for c in comment)
    new = f"{block}{ind}- name: HIDDEN_ENTITY_IDS\n{vind}value: \"{','.join(have + add)}\"\n"
    return text[:m.start()] + new + text[m.end():], add


def add_to_legal_hidden(text: str, entries: list[tuple[str, str]], comment: list[str]) -> tuple[str, list[str]]:
    """entries: [(profile id, 'gdpr-erasure-register-<n>')] appended at the end of LEGAL_HIDDEN_ENTITY_IDS."""
    m = re.search(r"^LEGAL_HIDDEN_ENTITY_IDS = \{\n(?P<body>.*?)^\}\n", text, re.M | re.S)
    if not m:
        raise ShapeError("LEGAL_HIDDEN_ENTITY_IDS dict not found")
    add = [(i, ref) for i, ref in entries if f'"{i}"' not in m.group("body")]
    if not add:
        return text, []
    block = "".join(f"    # {c}\n" for c in comment) + "".join(f'    "{i}": ("profile", "{ref}"),\n' for i, ref in add)
    pos = m.end("body")
    return text[:pos] + block + text[pos:], [i for i, _ in add]


def add_to_erasure_test(text: str, entries: list[tuple[str, str]]) -> tuple[str, list[str]]:
    """Extend ERASURE_PROFILES so the strict equality keeps its meaning (never loosen it: c3 handoff §4.4)."""
    m = re.search(r"^ERASURE_PROFILES = \{\n(?P<body>.*?)^\}\n", text, re.M | re.S)
    if not m:
        raise ShapeError("ERASURE_PROFILES set not found in the PDP test")
    add = [(i, ref) for i, ref in entries if f'"{i}"' not in m.group("body")]
    if not add:
        return text, []
    block = "".join(f'    # {ref.replace("gdpr-erasure-register-", "register #")} (gdpr-pipeline)\n    "{i}",\n'
                    for i, ref in add)
    pos = m.end("body")
    return text[:pos] + block + text[pos:], [i for i, _ in add]


def plan(rows: list[dict], hdevops_ids: set[str], pdp_ids: set[str], in_flight: dict[str, set[str]],
         include_legal: bool = False) -> list[dict]:
    """Identity-PASS PROFILE pages of open rows, most overdue first: [{id, register_no, basis, due_at, need}].
    `need` names the list(s) still missing the id AND not already carried by an open PR in that repository
    (in_flight = {"hdevops": ids, "pdp": ids}), so a batch whose second PR failed to open is retried for that
    half only.
    Legal hide-first pages join only with include_legal (the captain owns legal matters; the daily batch is
    built from PASS rows)."""
    from gdpr_pipeline.identity import IDENTITY_PASS, LEGAL_HIDE_FIRST
    HIDE_ELIGIBLE = IDENTITY_PASS + ((LEGAL_HIDE_FIRST,) if include_legal else ())
    # A page the register is holding for the CAPTAIN's own call stays out of the routine batch even when a DIFFERENT
    # row decides that same page PASS: the batch hides pages whose owner asked for their own page, while a legal
    # threat is a reply the captain owns. Rows share page ids in practice (register #126 and #246 both carry
    # 7871c617, which was withdrawn from an earlier batch for exactly this reason), and the batch dedups by PAGE, so
    # without this the second row would quietly overturn that withdrawal.
    held = {pv["id"] for r in rows
            if r["status"] == "open" and r.get("class") == "legal_threat"
            for pv in r["verdict_detail"] if pv["verdict"] == LEGAL_HIDE_FIRST}
    out, seen = [], set()
    for r in sorted(rows, key=lambda r: (r["due_at"], r["register_no"])):
        if r["status"] != "open":
            continue
        for pv in r["verdict_detail"]:
            pid = pv["id"]
            if pv["verdict"] not in HIDE_ELIGIBLE or pid in seen or not UUID_RE.fullmatch(pid):
                continue
            if pid in held and not include_legal:
                continue
            ent = next((p["entity"] for p in r["pages"] if p["id"] == pid), "profile")
            if ent != "profile":
                continue
            need = [n for n, s in (("hdevops", hdevops_ids), ("pdp", pdp_ids))
                    if pid not in s and pid not in in_flight.get(n, set())]
            if not need:
                continue
            seen.add(pid)
            out.append({"id": pid, "register_no": r["register_no"], "basis": pv["verdict"], "due_at": r["due_at"],
                        "need": need, "request_id": r["id"]})
    return out


def _comment(batch: list[dict], day: str) -> list[str]:
    regs = ", ".join(dict.fromkeys(f"#{b['register_no']}" for b in batch))
    return [f"{day} (gdpr-pipeline hide batch, GDPR Art. 17 register {regs}; identity per gdpr-ack-v2 §3).",
            "Reversible hide only: 410 + noindex, nothing deleted, no muso-cli delete. undo = remove the id + rollout."]


def edit_hdevops(texts: dict[str, str], batch: list[dict], day: str) -> tuple[dict[str, str], list[str]]:
    ids = [b["id"] for b in batch if "hdevops" in b["need"]]
    out, added = {}, []
    for path, text in texts.items():
        new, add = add_to_hidden_yaml(text, ids, _comment([b for b in batch if b["id"] in ids], day))
        out[path] = new
        added = added or add
    return out, added


def edit_pdp(list_text: str, test_text: str, batch: list[dict], day: str) -> tuple[str, str, list[str]]:
    entries = [(b["id"], f"gdpr-erasure-register-{b['register_no']}") for b in batch if "pdp" in b["need"]]
    new_list, added = add_to_legal_hidden(list_text, entries, _comment([b for b in batch if "pdp" in b["need"]], day))
    new_test, _ = add_to_erasure_test(test_text, [e for e in entries if e[0] in added])
    return new_list, new_test, added


def pr_body(kind: str, batch: list[dict], twin: str = "") -> str:
    rows = "\n".join(f"| #{b['register_no']} | `{b['id']}` | {b['basis']} | {b['due_at'][:10]} |" for b in batch)
    what = ("`HIDDEN_ENTITY_IDS` gives 410 + `x-robots-tag: noindex` on each public page (prod + the dev mirror)."
            if kind == "hdevops" else
            "`LEGAL_HIDDEN_ENTITY_IDS` stops the sitemaps advertising each page; the test's erasure set gains the same "
            "ids so the strict equality assertion keeps meaning what it says rather than being loosened.")
    tier = ("Tier: 1, because it changes a prod env value on the web edge (HIDDEN_ENTITY_IDS) and the reconciler rolls "
            "the pods on merge; the change is a reversible 410 + noindex hide, nothing is deleted, and undo is removing "
            "the ids and rolling out." if kind == "hdevops" else
            "Tier: 1, because it changes which ids the production sitemap generator omits; nothing is deleted, the page "
            "itself is hidden by the H-DevOps twin, and undo is removing the lines.")
    return (f"Daily GDPR erasure hide batch, generated by hydra `scripts/gdpr-pipeline.py hide-batch` from the "
            f"erasure register's identity-PASS rows (Fable `gdpr-ruling-for-jan.md` §3; identity paths per "
            f"`gdpr-ack-v2-and-arpad-1101.md` §3, decided by code from the core replica + the Intercom contact).\n\n"
            f"| register | id | identity | written confirmation due |\n|---|---|---|---|\n{rows}\n\n"
            f"This is the reversible hide only: {what} Nothing is deleted, there is no `DELETE /api/v3/admin/profile` "
            f"and no muso-cli delete. The pipeline never merges: a person does, and only the anonymous 410 read-back "
            f"marks a row hidden.\n\n{('Twin: ' + twin + chr(10) + chr(10)) if twin else ''}{tier}\n")


def _run(argv: list[str], cwd: str | None = None) -> str:
    p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=600)
    if p.returncode:
        raise RuntimeError(f"{' '.join(argv[:3])}: {p.stderr.strip()[-300:]}")
    return p.stdout.strip()


BATCH_BRANCH = "gdpr-pipeline/hide-"


def open_batch_prs(repo: str, runner=_run) -> list[dict]:
    """The pipeline's OWN unmerged hide-batch PRs in `repo` ([{number, url, headRefName}]). Identified by the branch
    prefix this module pushes, never by a title or a body mention."""
    listing = json.loads(runner(["gh", "pr", "list", "-R", repo, "--state", "open", "--limit", "100",
                                 "--json", "number,url,headRefName"]))
    return [pr for pr in listing if str(pr.get("headRefName") or "").startswith(BATCH_BRANCH)]


def open_prs(batch: list[dict], dry_run: bool = True, runner=_run) -> dict:
    """Clone both repos, apply the edits, and (unless dry_run) push a branch and open the two PRs.
    Returns {"hdevops": url|diff, "pdp": url|diff, "ids": [...], "deferred": {kind: url}}.

    ONE batch pair at a time per repository: both PRs of a batch insert at the same point in the same list file, so a
    second pair opened before the first merges merges as a conflict against a list of ids nobody has reviewed yet. A
    daily batch whose PR a person has not merged defers instead, and says which PR it is waiting for; the ids stay
    un-hidden and every later tick retries them."""
    all_ids = [b["id"] for b in batch]
    need = {k for b in batch for k in ("hdevops", "pdp") if k in b["need"]}
    deferred = {}
    for kind, repo in (("hdevops", HDEVOPS_REPO), ("pdp", PDP_REPO)):
        if kind not in need:
            continue
        prior = open_batch_prs(repo, runner=runner)
        if prior:
            deferred[kind] = prior[0].get("url") or f"{repo}#{prior[0].get('number')}"
    if deferred:
        batch = [dict(b, need=[n for n in b["need"] if n not in deferred]) for b in batch]
        batch = [b for b in batch if b["need"]]
        if not batch:
            return {"ids": all_ids, "hdevops": "", "pdp": "", "deferred": deferred}
    now = datetime.now(timezone.utc)
    day, branch = now.strftime("%Y-%m-%d"), BATCH_BRANCH + now.strftime("%Y%m%d-%H%M")
    out: dict = {"ids": [b["id"] for b in batch], "deferred": deferred}
    with tempfile.TemporaryDirectory(prefix="gdpr-hide-") as tmp:
        hd, pdp = Path(tmp, "hd"), Path(tmp, "pdp")
        _run(["gh", "repo", "clone", HDEVOPS_REPO, str(hd), "--", "--depth", "1"])
        _run(["gh", "repo", "clone", PDP_REPO, str(pdp), "--", "--depth", "1"])
        texts, hd_added = edit_hdevops({f: (hd / f).read_text() for f in HDEVOPS_FILES}, batch, day)
        lt, tt, pdp_added = edit_pdp((pdp / PDP_LIST).read_text(), (pdp / PDP_TEST).read_text(), batch, day)
        for repo_dir, files, added, kind in ((hd, texts, hd_added, "hdevops"),
                                             (pdp, {PDP_LIST: lt, PDP_TEST: tt}, pdp_added, "pdp")):
            if not added:
                continue
            for f, t in files.items():
                (repo_dir / f).write_text(t)
            if dry_run:
                out[kind] = _run(["git", "diff"], cwd=str(repo_dir))
                continue
            title = (f"feat(hide): GDPR erasure hide batch {day} (+{len(added)} ids, reversible)" if kind == "hdevops"
                     else f"feat(sitemap): stop advertising the GDPR erasure batch {day} (+{len(added)} ids)")
            _run(["git", "checkout", "-b", branch], cwd=str(repo_dir))
            _run(["git", "-c", f"user.name={GIT_NAME}", "-c", f"user.email={GIT_EMAIL}", "commit", "-am", title],
                 cwd=str(repo_dir))
            _run(["git", "push", "-u", "origin", branch], cwd=str(repo_dir))
            sub = [b for b in batch if b["id"] in added]
            # tier:1 like #4619/#2574; no-automerge because every hide is a person's decision (captain order).
            out[kind] = _run(["gh", "pr", "create", "--title", title, "--body",
                              pr_body(kind, sub, out.get("hdevops", "") if kind == "pdp" else ""),
                              "--head", branch, "--label", "tier:1", "--label", "no-automerge"],
                             cwd=str(repo_dir)).splitlines()[-1]
    return out


PR_SCAN_LIMIT = 1000        # `gh pr list` paginates internally to reach --limit; at the cap we stop trusting it


def in_flight_ids(ids: list[str], runner=_run) -> dict[str, set[str]]:
    """{"hdevops": ids, "pdp": ids} that an OPEN PR in that repository actually ADDS to its hide LIST.

    Per repository: an H-DevOps PR never stands in for the sitemap half, or the reverse.

    The test is what the PR CHANGES, not what its head file happens to contain (QA review 2026-11-03): the head file is
    parsed with the same parser the read-back uses and the PR's BASE file is subtracted from it, so a PR that targets a
    branch where an id already exists - changing no hide-list entry - cannot suppress the batch that is supposed to add
    it. A mention in the body, a comment, a reverted plan, a matching `value:` line under a DIFFERENT env name in the
    same manifest, and the sitemap TEST file all still suppress nothing.

    Two ways to claim nothing, both deliberate: an unreadable file (a PR that deleted it, a 404, a reshaped parse) and
    a PR list at the scan cap, where pagination stops being a proof. A duplicate PR is the safe miss; aborting the whole
    batch is not, because the pages then sit past their 24-hour deadline."""
    hit: dict[str, set[str]] = {"hdevops": set(), "pdp": set()}
    want = {i.lower() for i in ids}
    if not want:
        return hit
    targets = (("hdevops", HDEVOPS_REPO, (HDEVOPS_FILES[0],), hidden_ids_from_yaml),
               ("pdp", PDP_REPO, (PDP_LIST,), legal_hidden_from_py))
    for kind, repo, files, parse in targets:
        listing = json.loads(runner(["gh", "pr", "list", "-R", repo, "--state", "open",
                                     "--limit", str(PR_SCAN_LIMIT),
                                     "--json", "number,headRefOid,baseRefOid"]))
        if len(listing) >= PR_SCAN_LIMIT:
            continue          # a truncated view proves nothing about which PR added what
        for pr in listing:
            head, base = pr.get("headRefOid") or "", pr.get("baseRefOid") or ""
            if not head or not base:
                continue
            for f in files:
                try:
                    have = parse(runner(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                                         f"repos/{repo}/contents/{f}?ref={head}"]))
                    was = parse(runner(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                                        f"repos/{repo}/contents/{f}?ref={base}"]))
                except (Unknown, RuntimeError, OSError, ValueError, IndexError, AttributeError, KeyError):
                    # Unreadable (a nonzero `gh api` is a RuntimeError, not an Unknown) or reshaped: claim nothing.
                    continue
                hit[kind] |= (have - was) & want
    return hit
    targets = (("hdevops", HDEVOPS_REPO, (HDEVOPS_FILES[0],), hidden_ids_from_yaml),
               ("pdp", PDP_REPO, (PDP_LIST,), legal_hidden_from_py))
    for kind, repo, files, parse in targets:
        listing = json.loads(runner(["gh", "pr", "list", "-R", repo, "--state", "open", "--limit", "200",
                                     "--json", "number,headRefOid"]))
        for pr in listing:
            sha = pr.get("headRefOid") or ""
            if not sha:
                continue
            for f in files:
                try:
                    have = parse(runner(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                                         f"repos/{repo}/contents/{f}?ref={sha}"]))
                except (Unknown, RuntimeError, OSError, ValueError, IndexError, AttributeError, KeyError):
                    # Unreadable (a nonzero `gh api` is a RuntimeError, not an Unknown) or reshaped: claim nothing.
                    # A duplicate PR is the safe miss; aborting the whole batch is not -- an unrelated open PR that
                    # deleted the hide-list file would otherwise stop every eligible page from being prepared, past
                    # the 24-hour deadline. The `gh pr list` above stays fatal: without the list nothing is known.
                    continue
                hit[kind] |= have & want
    return hit
