"""The reversible-hide batch: one H-DevOps PR (HIDDEN_ENTITY_IDS, prod + dev -> 410 + noindex) and one
platform-data-processing PR (sitemap LEGAL_HIDDEN_ENTITY_IDS + its strict-equality test), generated from PASS rows.
Shape follows H-DevOps #4619 + PDP #2574 (Arpad, cs-systemic-c3).

The pipeline never hides by itself (captain standing order, c3 handoff §4.1): it PREPARES the PRs; a person
merges them, and only the 410 read-back (checks.public_gone) ever writes `hidden_at`. Nothing is deleted; there
is no `DELETE /api/v3/admin/profile` and no muso-cli delete anywhere in this module. Undo = remove the id.

Pages are profiles, tracks and albums. Both hide lists have always been keyed by entity id (the sitemap list already
carries tracks and one album from the 10-23 legal batch); what kept an item out was that nothing could decide one.
`identity.decide_item` now does, through the item's one artist, so `plan` takes whatever page the identity gate made
eligible and writes its real entity.

ONE LIVE PAIR, ALWAYS THE WHOLE SET (`open_prs`). Each run's PR carries EVERY id the register currently wants hidden
and that `main` does not have yet. When that set differs from what the pipeline's own open PR adds, a new PR is opened
from `main` and the old one is closed as superseded; when it is the same, nothing is touched. Nothing ever waits
"behind" an unmerged PR, and there are never two pipeline PRs editing the same line.

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


ENTITIES = ("profile", "track", "album")
# The PDP strict-equality test keeps the pipeline's ids in two named sets, and the pipeline only ever EXTENDS them:
#   ERASURE_PROFILES = {"<id>", ...}            every entry must be ("profile", "gdpr-erasure-register-N")
#   ERASURE_ITEMS = {"<id>": "track", ...}      a track / album; its entity is stated so the test can hold it to it
# ERASURE_ITEMS is a ONE-TIME change in platform-data-processing (docs/support/caroline-billing-and-hide.md gives the
# exact patch). Until it is there an item is not prepared at all - neither half - and the run says so: the alternative
# is rewriting that test's assertion from here, which is the loosening c3 handoff §4.4 forbids.
ITEMS_ANCHOR = "ERASURE_ITEMS"
_ITEMS_RE = re.compile(r"^ERASURE_ITEMS(?:[ \t]*:[^=\n]+)? = \{\n(?P<body>.*?)^\}\n", re.M | re.S)
_ITEMS_EMPTY_RE = re.compile(r"^(?P<head>ERASURE_ITEMS(?:[ \t]*:[^=\n]+)? = )\{\}\n", re.M)


class ItemAnchorMissing(ShapeError):
    pass


def _entry(e: tuple) -> tuple[str, str, str]:
    """(id, ref) is a profile (the shape before items existed); (id, entity, ref) states its entity."""
    i, ent, ref = (e[0], "profile", e[1]) if len(e) == 2 else e
    if ent not in ENTITIES:
        raise ShapeError(f"{ent!r} is not a page entity the hide lists know")
    return i, ent, ref


def has_items_anchor(test_text: str) -> bool:
    return bool(_ITEMS_RE.search(test_text) or _ITEMS_EMPTY_RE.search(test_text))


def add_to_legal_hidden(text: str, entries: list[tuple], comment: list[str]) -> tuple[str, list[str]]:
    """entries: [(id, entity, 'gdpr-erasure-register-<n>')] appended at the end of LEGAL_HIDDEN_ENTITY_IDS."""
    m = re.search(r"^LEGAL_HIDDEN_ENTITY_IDS = \{\n(?P<body>.*?)^\}\n", text, re.M | re.S)
    if not m:
        raise ShapeError("LEGAL_HIDDEN_ENTITY_IDS dict not found")
    add = [e for e in map(_entry, entries) if f'"{e[0]}"' not in m.group("body")]
    if not add:
        return text, []
    block = ("".join(f"    # {c}\n" for c in comment)
             + "".join(f'    "{i}": ("{ent}", "{ref}"),\n' for i, ent, ref in add))
    pos = m.end("body")
    return text[:pos] + block + text[pos:], [i for i, _, _ in add]


def add_to_erasure_test(text: str, entries: list[tuple]) -> tuple[str, list[str]]:
    """Extend the test's own sets so the strict equality keeps its meaning (never loosen it: c3 handoff §4.4).
    Profiles go to ERASURE_PROFILES, a track / album to ERASURE_ITEMS with its entity."""
    ents = [_entry(e) for e in entries]
    added: list[str] = []
    profiles = [(i, ref) for i, ent, ref in ents if ent == "profile"]
    items = [e for e in ents if e[1] != "profile"]
    if profiles:
        m = re.search(r"^ERASURE_PROFILES = \{\n(?P<body>.*?)^\}\n", text, re.M | re.S)
        if not m:
            raise ShapeError("ERASURE_PROFILES set not found in the PDP test")
        add = [(i, ref) for i, ref in profiles if f'"{i}"' not in m.group("body")]
        block = "".join(f'    # {ref.replace("gdpr-erasure-register-", "register #")} (gdpr-pipeline)\n    "{i}",\n'
                        for i, ref in add)
        text = text[:m.end("body")] + block + text[m.end("body"):]
        added += [i for i, _ in add]
    if items:
        text = _ITEMS_EMPTY_RE.sub(lambda e: e.group("head") + "{\n}\n", text, count=1)
        m = _ITEMS_RE.search(text)
        if not m:
            raise ItemAnchorMissing(f"{ITEMS_ANCHOR} dict not found in the PDP test: a track / album cannot be added "
                                    f"until the one-time platform-data-processing change is merged")
        add = [e for e in items if f'"{e[0]}"' not in m.group("body")]
        block = "".join(f'    # {ref.replace("gdpr-erasure-register-", "register #")} (gdpr-pipeline)\n'
                        f'    "{i}": "{ent}",\n' for i, ent, ref in add)
        text = text[:m.end("body")] + block + text[m.end("body"):]
        added += [i for i, _, _ in add]
    return text, added


def plan(rows: list[dict], hdevops_ids: set[str], pdp_ids: set[str], in_flight: dict[str, set[str]],
         include_legal: bool = False) -> list[dict]:
    """Identity-PASS pages of open rows, most overdue first: [{id, entity, register_no, basis, due_at, need}].
    A page is a profile, a track or an album; which of them may pass is `identity`'s decision, not this function's
    (a track / album passes only through its one artist: identity.decide_item).
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
            ent = next((p.get("entity") or "profile" for p in r["pages"] if p["id"] == pid), "profile")
            if ent not in ENTITIES:
                continue
            need = [n for n, s in (("hdevops", hdevops_ids), ("pdp", pdp_ids))
                    if pid not in s and pid not in in_flight.get(n, set())]
            if not need:
                continue
            seen.add(pid)
            out.append({"id": pid, "entity": ent, "register_no": r["register_no"], "basis": pv["verdict"],
                        "due_at": r["due_at"], "need": need, "request_id": r["id"]})
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
    sub = [b for b in batch if "pdp" in b["need"]]
    entries = [(b["id"], b.get("entity") or "profile", f"gdpr-erasure-register-{b['register_no']}") for b in sub]
    new_list, added = add_to_legal_hidden(list_text, entries, _comment(sub, day))
    new_test, _ = add_to_erasure_test(test_text, [e for e in entries if e[0] in added])
    return new_list, new_test, added


def pr_body(kind: str, batch: list[dict], twin: str = "") -> str:
    rows = "\n".join(f"| #{b['register_no']} | `{b['id']}` | {b.get('entity') or 'profile'} | {b['basis']} | "
                     f"{b['due_at'][:10]} |" for b in batch)
    items = ("\n\nA track / album row is here because the catalog gives it exactly ONE artist and that artist's profile "
             "passes the same identity gate for this requester (`identity.decide_item`); a page with two artists, a "
             "big page, or an artist we could not read never reaches a batch."
             if any((b.get("entity") or "profile") != "profile" for b in batch) else "")
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
            f"| register | id | page | identity | written confirmation due |\n|---|---|---|---|---|\n{rows}{items}\n\n"
            f"This PR carries the WHOLE set the register wants hidden and `main` does not have yet. When that set "
            f"changes the pipeline opens a new PR and closes this one as superseded, so a review is always of exactly "
            f"the ids in this table.\n\n"
            f"This is the reversible hide only: {what} Nothing is deleted, there is no `DELETE /api/v3/admin/profile` "
            f"and no muso-cli delete. The pipeline never merges: a person does, and only the anonymous 410 read-back "
            f"marks a row hidden.\n\n{('Twin: ' + twin + chr(10) + chr(10)) if twin else ''}{tier}\n")


def _run(argv: list[str], cwd: str | None = None) -> str:
    p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=600)
    if p.returncode:
        raise RuntimeError(f"{' '.join(argv[:3])}: {p.stderr.strip()[-300:]}")
    return p.stdout.strip()


BATCH_BRANCH = "gdpr-pipeline/hide-"
KINDS = (("hdevops", HDEVOPS_REPO, HDEVOPS_FILES[0], hidden_ids_from_yaml),
         ("pdp", PDP_REPO, PDP_LIST, legal_hidden_from_py))
_UNREADABLE = (Unknown, RuntimeError, OSError, ValueError, IndexError, AttributeError, KeyError)


def open_batch_prs(repo: str, runner=_run) -> list[dict]:
    """The pipeline's OWN unmerged hide-batch PRs in `repo`, oldest first ([{number, url, headRefName, ...}]).
    Identified by the branch prefix this module pushes, never by a title or a body mention."""
    listing = json.loads(runner(["gh", "pr", "list", "-R", repo, "--state", "open", "--limit", "100",
                                 "--json", "number,url,headRefName,headRefOid,baseRefOid,mergeable"]))
    own = [pr for pr in listing if str(pr.get("headRefName") or "").startswith(BATCH_BRANCH)]
    return sorted(own, key=lambda pr: int(pr.get("number") or 0))


def pr_adds(repo: str, path: str, parse, pr: dict, runner=_run) -> set[str] | None:
    """The ids this PR ADDS to its hide list: head file minus base file, both read with the read-back's own parser.
    None when that cannot be established (no sha, a deleted file, a reshaped parse): never an empty set, because
    "adds nothing" and "could not read" lead to different actions."""
    head, base = pr.get("headRefOid") or "", pr.get("baseRefOid") or ""
    if not head or not base:
        return None
    try:
        have = parse(runner(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                             f"repos/{repo}/contents/{path}?ref={head}"]))
        was = parse(runner(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                            f"repos/{repo}/contents/{path}?ref={base}"]))
    except _UNREADABLE:
        # Unreadable (a nonzero `gh api` is a RuntimeError, not an Unknown) or reshaped.
        return None
    return {i.lower() for i in have - was}


def own_added(runner=_run) -> dict[str, set[str] | None]:
    """{"hdevops": ids, "pdp": ids}: what the pipeline's OWN open PRs add, per repository. None for a repository
    where one of them could not be read - which is not "adds nothing"."""
    out: dict[str, set[str] | None] = {}
    for kind, repo, path, parse in KINDS:
        ids: set[str] | None = set()
        for pr in open_batch_prs(repo, runner=runner):
            got = pr_adds(repo, path, parse, pr, runner=runner)
            if got is None:
                ids = None
                break
            ids |= got
        out[kind] = ids
    return out


def carry_legal(routine: list[dict], legal: list[dict], own: dict[str, set[str] | None]) -> list[dict]:
    """The routine batch, plus every legal hide-first id a `--include-legal` run already put in an open pipeline PR.

    `--include-legal` is the captain's GO, given on one run. That run's PR is where the GO is recorded. Because each
    pipeline PR carries the whole set and replaces the last one, a routine run six hours later would otherwise open
    a PR WITHOUT those ids and close the captain's one as superseded - withdrawing a hide he ordered, with a polite
    comment. So an id stays in the set while (a) an open pipeline PR still adds it and (b) the register still wants
    it (`legal` is the include-legal plan computed NOW, so a row that closed or changed verdict drops out).

    It never adds a legal id on its own: an id no open pipeline PR carries is not here, GO or no GO."""
    have = {b["id"] for b in routine}
    carried = [b for b in legal if b["id"] not in have
               and any(b["id"].lower() in (own.get(kind) or set()) for kind in b["need"])]
    return sorted(routine + carried, key=lambda b: (b["due_at"], b["register_no"] or 0))


SUPERSEDED = ("Superseded by {url}: the erasure register's hide set changed, and each pipeline PR carries the whole "
              "set, so that one replaces this one. Nothing here was merged; no page was hidden by this PR.")
CONFLICTED = ("Superseded by {url}: `main` changed the hide list after this PR was opened, so this one could no longer "
              "be merged. The replacement carries the whole set from the current `main`. Nothing here was merged; no "
              "page was hidden by this PR.")
NOTHING_LEFT = ("Closed by the pipeline: nothing in this PR is still waiting. Every id it added is either on `main` "
                "already or no longer hide-eligible in the erasure register. Nothing here was merged.")


# Reviewed baseline: deploy overwrites - 2026-11-12 (caroline-billing-and-hide-k3, firstmate inbox 003): node-8 holds
# a hand edit of this file made 2026-11-10T00:51Z (backup hide_batch.py.bak-stale-20261110T005131Z, never committed):
# an own batch PR older than 24 h stopped deferring the next pair, capped at five open pairs per repository. Read
# against this blob: its purpose (an unmerged batch PR must not block the queue) is met here at every age, because
# open_prs never defers, and its cap is met by construction, because each repository has one pipeline PR. It adds
# nothing this blob lacks, and it is what opened the out-of-step pairs (H-DevOps #5105, PDP #2582 / #2583) that the
# first run of this blob replaces with one pair. The 2026-11-12 04:04Z deploy halted on exactly this conflict.
def open_prs(batch: list[dict], dry_run: bool = True, runner=_run) -> dict:
    """Bring each repository's ONE pipeline PR in line with the batch, and (unless dry_run) push and open what changed.

    Returns {"ids", "hdevops": url|diff|"", "pdp": url|diff|"", "opened": {kind: url}, "kept": {kind: url},
             "superseded": {kind: [url]}, "blocked_items": [..], "close_failed": [..], "unreadable": {kind: url}}.

    WHY NOT "one pair at a time, the next batch waits" (what this replaced). Both PRs of a batch edit the same line
    of the same file, so two open pipeline PRs do conflict - that part was right. But waiting made every later id
    queue behind a PR nobody had merged yet, and because the two repositories defer independently the halves fell
    out of step: measured 2026-11-10/11, the H-DevOps half of one id waited behind the PDP PR of the day before
    while its PDP half opened, and the next day the reverse - a page half-hidden for as long as the reviews
    alternated. A hide that is due in 24 hours cannot queue behind a review.

    So there is one pipeline PR per repository and it always carries the WHOLE set (`batch` is every id `main` does
    not have and no other PR adds). Per repository:
      - the pipeline's newest open PR already adds exactly that set  -> it is left alone (a review in progress stays
        a review of the same ids) - unless GitHub says it CONFLICTS with `main` (the hide list is one line, so any
        other merge to it does that): a PR nobody can merge is re-issued from `main` like a changed set;
      - otherwise a new PR is opened from `main` with the whole set, and every older pipeline PR is closed as
        superseded with a comment naming the new one. A new PR, never a force-push: an approval of the old ids must
        not ride along onto ids the reviewer never saw;
      - the register wants nothing more from that repository -> stale pipeline PRs are closed with the reason;
      - what an open pipeline PR adds cannot be read -> nothing in that repository is opened or closed this run
        (`unreadable`), because replacing a PR whose contents are unknown could drop an id somebody put there.
    A person still merges. Closing is the one thing here that is not an addition, and it only ever touches PRs on
    this module's own branch prefix.

    A track / album whose sitemap half needs the PDP test's ERASURE_ITEMS set, when that set is not in the test
    yet, is left out of BOTH halves (never half a hide on purpose) and named in `blocked_items`."""
    out: dict = {"ids": [b["id"] for b in batch], "hdevops": "", "pdp": "", "opened": {}, "kept": {},
                 "superseded": {}, "blocked_items": [], "close_failed": [], "unreadable": {}}
    items = [b for b in batch if (b.get("entity") or "profile") != "profile" and "pdp" in b["need"]]
    if items:
        try:
            anchored = has_items_anchor(runner(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                                                f"repos/{PDP_REPO}/contents/{PDP_TEST}?ref=main"]))
        except _UNREADABLE:
            anchored = False          # unread is not "present": the item waits, the profiles go
        if not anchored:
            out["blocked_items"] = [b["id"] for b in items]
            batch = [b for b in batch if b["id"] not in set(out["blocked_items"])]
    own = {kind: open_batch_prs(repo, runner=runner) for kind, repo, _, _ in KINDS}
    want = {kind: {b["id"].lower() for b in batch if kind in b["need"]} for kind, _, _, _ in KINDS}
    todo, stale, conflicted = [], {}, set()
    for kind, repo, path, parse in KINDS:
        prs = own[kind]
        adds = [pr_adds(repo, path, parse, pr, runner=runner) for pr in prs]
        if any(a is None for a in adds):
            # What an open pipeline PR adds could not be read, so this run cannot tell whether replacing it would
            # drop an id a person (or the captain's --include-legal run) put there. Touch nothing in this repository.
            bad = prs[[a is None for a in adds].index(True)]
            out["unreadable"][kind] = bad.get("url") or f"{repo}#{bad.get('number')}"
            stale[kind] = []
            continue
        if prs and want[kind] and adds[-1] == want[kind] and prs[-1].get("mergeable") == "CONFLICTING":
            conflicted.add(kind)      # only an explicit CONFLICTING: UNKNOWN is GitHub still computing, not a verdict
        if prs and want[kind] and adds[-1] == want[kind] and kind not in conflicted:
            out["kept"][kind] = out[kind] = prs[-1].get("url") or f"{repo}#{prs[-1].get('number')}"
            stale[kind] = prs[:-1]
        else:
            stale[kind] = prs
            if want[kind]:
                todo.append(kind)
    now = datetime.now(timezone.utc)
    day, branch = now.strftime("%Y-%m-%d"), BATCH_BRANCH + now.strftime("%Y%m%d-%H%M")
    if todo:
        with tempfile.TemporaryDirectory(prefix="gdpr-hide-") as tmp:
            for kind, repo, _, _ in KINDS:
                if kind not in todo:
                    continue
                repo_dir = Path(tmp, kind)
                runner(["gh", "repo", "clone", repo, str(repo_dir), "--", "--depth", "1"])
                if kind == "hdevops":
                    files, added = edit_hdevops({f: (repo_dir / f).read_text() for f in HDEVOPS_FILES}, batch, day)
                else:
                    lt, tt, added = edit_pdp((repo_dir / PDP_LIST).read_text(), (repo_dir / PDP_TEST).read_text(),
                                             batch, day)
                    files = {PDP_LIST: lt, PDP_TEST: tt}
                if not added:
                    continue          # `main` gained the ids between the plan and the clone
                for f, t in files.items():
                    (repo_dir / f).write_text(t)
                if dry_run:
                    out[kind] = runner(["git", "diff"], cwd=str(repo_dir))
                    continue
                title = (f"feat(hide): GDPR erasure hide batch {day} (+{len(added)} ids, reversible)"
                         if kind == "hdevops"
                         else f"feat(sitemap): stop advertising the GDPR erasure batch {day} (+{len(added)} ids)")
                runner(["git", "checkout", "-b", branch], cwd=str(repo_dir))
                runner(["git", "-c", f"user.name={GIT_NAME}", "-c", f"user.email={GIT_EMAIL}", "commit", "-am", title],
                       cwd=str(repo_dir))
                runner(["git", "push", "-u", "origin", branch], cwd=str(repo_dir))
                sub = [b for b in batch if b["id"] in added]
                twin = out["hdevops"] if kind == "pdp" and str(out["hdevops"]).startswith("http") else ""
                # tier:1 like #4619/#2574; no-automerge because every hide is a person's decision (captain order).
                out[kind] = out["opened"][kind] = runner(
                    ["gh", "pr", "create", "--title", title, "--body", pr_body(kind, sub, twin),
                     "--head", branch, "--label", "tier:1", "--label", "no-automerge"],
                    cwd=str(repo_dir)).splitlines()[-1]
    for kind, repo, _, _ in KINDS:
        live = out["opened"].get(kind) or out["kept"].get(kind) or ""
        if kind in todo and not live:
            continue                  # nothing replaced the old PR (dry run, or no PR was needed): leave it be
        for pr in stale[kind]:
            url = pr.get("url") or f"{repo}#{pr.get('number')}"
            out["superseded"].setdefault(kind, []).append(url)
            if dry_run:
                continue
            try:
                runner(["gh", "pr", "close", str(pr["number"]), "-R", repo, "--comment",
                        (CONFLICTED if kind in conflicted else SUPERSEDED).format(url=live) if live
                        else NOTHING_LEFT])
            except _UNREADABLE as exc:
                # The new PR is the review artefact and it exists; an old one left open is closed by the next run.
                out["close_failed"].append(f"{url}: {exc}")
    return out


PR_SCAN_LIMIT = 1000        # `gh pr list` paginates internally to reach --limit; at the cap we stop trusting it


def in_flight_ids(ids: list[str], runner=_run) -> dict[str, set[str]]:
    """{"hdevops": ids, "pdp": ids} that an OPEN PR in that repository actually ADDS to its hide LIST - any PR EXCEPT
    the pipeline's own batch PRs. The pipeline's own PR is not "somebody else already has it": `open_prs` owns that
    PR and re-issues it with the whole set, so its ids must stay in the plan.

    Per repository: an H-DevOps PR never stands in for the sitemap half, or the reverse.

    The test is what the PR CHANGES, not what its head file happens to contain (QA review 2026-11-03): the head file is
    parsed with the same parser the read-back uses and the PR's BASE file is subtracted from it, so a PR that targets a
    branch where an id already exists - changing no hide-list entry - cannot suppress the batch that is supposed to add
    it. A mention in the body, a comment, a reverted plan, a matching `value:` line under a DIFFERENT env name in the
    same manifest, and the sitemap TEST file all still suppress nothing.

    Two ways to claim nothing, both deliberate: an unreadable file (a PR that deleted it, a 404, a reshaped parse) and
    a PR list at the scan cap, where pagination stops being a proof. A duplicate PR is the safe miss; aborting the whole
    batch is not, because the pages then sit past their 24-hour deadline. The `gh pr list` itself stays fatal: without
    the list nothing is known."""
    hit: dict[str, set[str]] = {"hdevops": set(), "pdp": set()}
    want = {i.lower() for i in ids}
    if not want:
        return hit
    for kind, repo, path, parse in KINDS:
        listing = json.loads(runner(["gh", "pr", "list", "-R", repo, "--state", "open",
                                     "--limit", str(PR_SCAN_LIMIT),
                                     "--json", "number,headRefOid,baseRefOid,headRefName"]))
        if len(listing) >= PR_SCAN_LIMIT:
            continue          # a truncated view proves nothing about which PR added what
        for pr in listing:
            if str(pr.get("headRefName") or "").startswith(BATCH_BRANCH):
                continue
            hit[kind] |= (pr_adds(repo, path, parse, pr, runner=runner) or set()) & want
    return hit
