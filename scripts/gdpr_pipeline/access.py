"""The Art. 15 answer: the copy of the personal data held on one account, built by code.

GDPR Art. 15(3): "The controller shall provide a copy of the personal data undergoing processing."

What this module does, and where it stops:

  * `collect` reads every row keyed to ONE account from the sources listed in `policies/gdpr-access-sources.json`,
    on the read-only replica, and returns one document. `package` turns it into canonical bytes with a sha256.
  * The document says what it covers and what it does not. It is COMPLETE only when every source was read, the
    replica shows no account-keyed table the manifest does not know, every other system that holds personal data is
    covered, the Art. 15(1) information has approved text, and the included columns have been reviewed for other
    people's data. Anything else is `complete: false` with each reason
    named. "I could not read it" and "there is none" are never the same answer: a source that did not read is
    `unknown`, never an empty list.
  * Nothing here sends. An incomplete document is a record of work done, never the answer. Delivery is not built in
    this module (docs/support/gdpr-pipeline.md, "The Art. 15 answer").

Whose data: the account the requester CONTROLS (the identity chain's first gate, `dsar.gates`: signed in, or writing
from the address on the account). The copy is of that account's data and of nothing else, so a page the requester
names but has not claimed adds nothing to it.

No I/O of its own: `reader` is `sources.trino_wide` in production (whole values, however long) and a fake in the
tests.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

MANIFEST_PATH = Path(__file__).resolve().parents[2] / "policies" / "gdpr-access-sources.json"
KIND = "gdpr-access-answer"
FRESH_HOURS = 24            # a copy older than this is rebuilt before it is sent: it must be the data as it is now
# The only delivery route is a mail attachment, and the mailbox takes 25 MB encoded (about 18 MB of file). A copy over
# this is held with the reason named, never posted to fail: a failed mail is `unknown` and is not retried. Measured on
# the live replica 2026-11-12: one of 23 copies was 25.5 MB.
ATTACH_MAX_BYTES = 18 * 1024 * 1024
MATCHING = ("Rows are matched to the account by its account number. Tables that hold an email address instead are "
            "matched on the sign-in address exactly as it is stored on the account, and on the same address in lower "
            "case.")
READ, UNKNOWN, TOO_LARGE = "read", "unknown", "too_large"
NUMERIC = ("bigint", "integer", "smallint", "decimal", "double", "real")


class ManifestError(Exception):
    """The manifest cannot be read or is not usable. Nothing is built."""


def load_manifest(path: Path | None = None) -> dict:
    p = Path(path or MANIFEST_PATH)
    try:
        raw = p.read_bytes()
        doc = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise ManifestError(f"cannot read {p}: {exc}") from exc
    seen = set()
    for s in doc.get("sources") or []:
        if not s.get("table") or not s.get("keys") or s["table"] in seen:
            raise ManifestError(f"source {s.get('table')!r}: needs a table named once and at least one key")
        seen.add(s["table"])
        for k in s["keys"]:
            if k.get("by") not in ("account_id", "account_email") or not _ident(k.get("column", "")):
                raise ManifestError(f"source {s['table']}: bad key {k!r}")
        for col, why in (s.get("withheld") or {}).items():
            if why not in doc.get("withheld_reasons", {}):
                raise ManifestError(f"source {s['table']}.{col}: withheld for {why!r}, which has no stated reason")
    if "users" not in seen:
        raise ManifestError("no `users` source: the account record itself is the first thing an answer holds")
    doc["_sha256"] = hashlib.sha256(raw).hexdigest()
    return doc


def _ident(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z_][a-z0-9_]*", name or ""))


def _lit(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


# ---- the replica's own account of itself

def discover(reader) -> dict[str, list[tuple[str, str]]]:
    """{table: [(column, type), ...]} for every base table and view in the core schema, in column order."""
    out: dict[str, list[tuple[str, str]]] = {}
    for row in reader("SELECT table_name, column_name, data_type FROM postgresql_core.information_schema.columns "
                      "WHERE table_schema = 'public' ORDER BY table_name, ordinal_position"):
        if len(row) != 3:
            raise ValueError(f"schema read returned a row of {len(row)} fields")
        out.setdefault(row[0], []).append((row[1], row[2].split("(")[0].strip().lower()))
    if "users" not in out:
        raise ValueError("schema read returned no `users` table: not the core schema, or not all of it")
    return out


def unclassified(manifest: dict, schema: dict) -> list[str]:
    """Tables the replica shows with an account-looking key that the manifest neither reads nor sets aside."""
    known = {s["table"] for s in manifest["sources"]} | set(manifest.get("ignored") or {})
    want = {c.lower() for c in manifest.get("discovery_columns") or []}
    return sorted(t for t, cols in schema.items() if t not in known and any(c.lower() in want for c, _ in cols))


def _scrub(msg: str) -> str:
    """An error text with every literal taken out: a reason is written to the trail and printed, and the query it
    quotes carries the account's id and address."""
    return re.sub(r"\d{3,}", "?", re.sub(r"'[^']*'", "'?'", msg))[:160]


# ---- one source

def _esc(expr: str) -> str:
    # One CSV line per row: `sources.trino` keeps only lines that start with a quote, so a value holding a newline
    # would lose its tail without a word. Escaped here, restored in `_unesc`.
    return (f"replace(replace(replace({expr}, chr(92), chr(92) || chr(92)), chr(10), chr(92) || 'n'), "
            f"chr(13), chr(92) || 'r')")


def _unesc(v: str) -> str:
    out, i = [], 0
    while i < len(v):
        if v[i] == "\\" and i + 1 < len(v):
            out.append({"n": "\n", "r": "\r", "\\": "\\"}.get(v[i + 1], v[i:i + 2]))
            i += 2
        else:
            out.append(v[i])
            i += 1
    return "".join(out)


def columns_of(source: dict, cols: list[tuple[str, str]], manifest: dict) -> tuple[list[tuple[str, str]], dict]:
    """(columns to read, {column: reason withheld}). A secret-looking column nobody has ruled on is withheld as
    `unreviewed`, never read: a new token column must not reach a requester because nobody looked."""
    withheld = dict(source.get("withheld") or {})
    reviewed = set(source.get("reviewed") or [])
    keys = {k["column"] for k in source["keys"]}
    secret = re.compile(manifest.get("secret_like") or "$^", re.I)
    keep = []
    for col, typ in cols:
        if col in withheld:
            continue
        if secret.search(col) and col not in reviewed and col not in keys:
            withheld[col] = "unreviewed"
            continue
        keep.append((col, typ))
    return keep, withheld


def select_sql(source: dict, keep: list[tuple[str, str]], types: dict, account_id: int, email: str,
               ceiling: int) -> str:
    preds = []
    for k in source["keys"]:
        col, typ = k["column"], types[k["column"]]
        if k["by"] == "account_id":
            preds.append(f"{col} = {int(account_id)}" if typ in NUMERIC else f"{col} = {_lit(int(account_id))}")
        elif email:
            # Equality, so the database does the match: a function over the column would make the replica hand
            # every row of the table to the query engine. The cost is stated in the copy (`matching`).
            forms = sorted({email, email.lower()})
            preds.append(f"{col} IN ({', '.join(_lit(f) for f in forms)})")
    if not preds:
        return ""
    exprs = [_esc(f"json_format({c})" if t == "json" else f"CAST({c} AS varchar)") for c, t in keep]
    return (f"SELECT {', '.join(exprs)} FROM postgresql_core.public.{source['table']} "
            f"WHERE {' OR '.join(preds)} LIMIT {int(ceiling) + 1}")


def read_source(source: dict, schema: dict, manifest: dict, account_id: int, email: str, reader) -> dict:
    table = source["table"]
    sec = {"table": table, "state": UNKNOWN, "reason": "", "columns": [], "rows": [], "withheld": {}}
    cols = schema.get(table)
    if not cols or not _ident(table):
        sec["reason"] = "the table is not in the database any more"
        return sec
    types = dict(cols)
    gone = [k["column"] for k in source["keys"] if k["column"] not in types]
    if gone:
        sec["reason"] = f"key column(s) gone: {', '.join(gone)}"
        return sec
    keep, withheld = columns_of(source, cols, manifest)
    if any(not _ident(c) for c, _ in keep):
        sec["reason"] = "a column name that cannot be read safely"
        return sec
    sec["withheld"], sec["columns"] = withheld, [c for c, _ in keep]
    ceiling = int(manifest.get("row_ceiling") or 0)
    sql = select_sql(source, keep, types, account_id, email, ceiling)
    if not sql:
        sec["reason"] = "keyed by the account's email address, and the account has none on record"
        return sec
    try:
        rows = reader(sql)
    except Exception as exc:        # noqa: BLE001 - any failed read is the same answer: unknown, with its reason
        sec["reason"] = f"the read did not complete: {type(exc).__name__}: {_scrub(str(exc))}"
        return sec
    if any(len(r) != len(keep) for r in rows):
        sec["reason"] = "the read returned a row with the wrong number of fields"
        return sec
    if ceiling and len(rows) > ceiling:
        sec["state"], sec["reason"] = TOO_LARGE, f"more than {ceiling} rows: not read in full"
        return sec
    sec["rows"] = sorted(([_unesc(v) for v in r] for r in rows), key=lambda r: json.dumps(r))
    sec["state"] = READ
    return sec


# ---- the whole answer

def collect(manifest: dict, account_id: int, reader, register: dict | None = None) -> dict:
    """The answer document for one account. Raises only when the schema itself cannot be read (then nothing is
    known, and there is no document to speak of); every per-source failure is recorded inside the document."""
    schema = discover(reader)
    by_table = {s["table"]: s for s in manifest["sources"]}
    users = read_source(by_table["users"], schema, manifest, account_id, "", reader)
    email = ""
    if users["state"] == READ and len(users["rows"]) == 1 and "email" in users["columns"]:
        email = users["rows"][0][users["columns"].index("email")]
    elif users["state"] == READ:
        users["state"], users["reason"] = UNKNOWN, f"{len(users['rows'])} account rows for one account id"
        users["rows"] = []
    sections = [users] + [read_source(s, schema, manifest, account_id, email, reader)
                          for s in manifest["sources"] if s["table"] != "users"]
    incomplete = [f"{s['table']}: {s['reason']}" for s in sections if s["state"] != READ]
    incomplete += [f"{s['table']}.{c}: not reviewed for inclusion" for s in sections
                   for c, why in sorted(s["withheld"].items()) if why == "unreviewed"]
    incomplete += [f"{t}: holds an account key and is not in the manifest" for t in unclassified(manifest, schema)]
    incomplete += standing_gaps(manifest)
    notice = (manifest.get("information_notice") or {}).get("text") or ""
    return {
        "v": 1, "kind": KIND, "account_id": int(account_id), "manifest_sha256": manifest.get("_sha256", ""),
        "rule": "GDPR Art. 15(3): \"The controller shall provide a copy of the personal data undergoing processing.\"",
        "information": notice,
        "matching": MATCHING,
        "withheld_reasons": manifest.get("withheld_reasons") or {},
        "register": register or {},
        "sections": sections,
        "complete": not incomplete, "incomplete": incomplete,
    }


def standing_gaps(manifest: dict) -> list[str]:
    """What makes EVERY copy incomplete, whoever the account is. While this is not empty no Art. 15 answer can be
    produced, so no message may state a date for one (`dsar.owed(answerable=...)`)."""
    gaps = [f"{x['id']}: not covered ({x['holds']})" for x in manifest.get("systems") or [] if not x.get("covered")]
    if not (manifest.get("information_notice") or {}).get("text"):
        gaps.append("the Art. 15(1) information has no approved text")
    if (manifest.get("column_review") or {}).get("reviewed") is not True:
        gaps.append("the included columns have not been reviewed for other people's data (Art. 15(4))")
    return gaps


def package(doc: dict) -> tuple[bytes, str]:
    """Canonical bytes (sorted keys, no clock, no run id) and their sha256: the same data gives the same hash."""
    raw = (json.dumps(doc, sort_keys=True, ensure_ascii=False, indent=1) + "\n").encode("utf-8")
    return raw, hashlib.sha256(raw).hexdigest()


def summary(doc: dict, sha: str = "", size: int = 0) -> dict:
    """Counts only, never a value: what may be printed, logged and written to the trail."""
    return {
        "sha256": sha, "bytes": size, "complete": doc["complete"], "incomplete": list(doc["incomplete"]),
        "manifest_sha256": doc["manifest_sha256"],
        "sources": len(doc["sections"]),
        "sources_read": sum(1 for s in doc["sections"] if s["state"] == READ),
        "sources_with_rows": sum(1 for s in doc["sections"] if s["rows"]),
        "rows": sum(len(s["rows"]) for s in doc["sections"]),
        "withheld_columns": sum(len(s["withheld"]) for s in doc["sections"]),
        "rows_by_source": {s["table"]: len(s["rows"]) for s in doc["sections"] if s["rows"]},
    }


def register_view(row: dict, sends: list[dict]) -> dict:
    """What the erasure register holds about this request, for the copy: dates and states, as recorded."""
    return {
        "register_no": row.get("register_no"), "class": row.get("class"), "channel": row.get("channel"),
        "received_at": row.get("received_at") or "", "requester_name": row.get("requester_name") or "",
        "requester_email": row.get("requester_email") or "", "pages": row.get("pages") or [],
        "messages_sent": [{"kind": s.get("kind"), "at": s.get("at")} for s in sends if s.get("state") == "sent"],
    }


def account_email(doc: dict) -> str:
    """The sign-in address on the account, as read into the copy. The ONLY address a copy is ever sent to: the
    address a request was written from is whatever the requester typed."""
    users = next((s for s in doc.get("sections") or [] if s.get("table") == "users"), None)
    if not users or users.get("state") != READ or len(users.get("rows") or []) != 1 or "email" not in users["columns"]:
        return ""
    return (users["rows"][0][users["columns"].index("email")] or "").strip()


def undeliverable(answer: dict | None, raw: bytes | None, account_now, age_hours: float,
                  email_now: str | None = None) -> list[str]:
    """Every reason this recorded copy may NOT be sent; [] only when it may. Pure: the caller reads the file, the
    clock and the account. One reason is enough to hold, and all of them are named.

    `email_now` is the sign-in address on the account read at send time (None: it could not be read). The copy
    carries the address as it was at build, up to FRESH_HOURS ago, and an account whose address changed since is
    still the same account by its id: sending to the address in the file would post the whole copy to an address
    the account no longer uses. So the two must be the same string, or the copy is held until it is rebuilt."""
    if not answer:
        return ["no copy has been built for this request"]
    why = []
    if not answer.get("complete"):
        why.append(f"the copy is not complete ({len(answer.get('summary', {}).get('incomplete', []))} gap(s) "
                   f"named in it): a partial copy is never sent as the answer")
    if raw is None:
        why.append("the recorded file cannot be read")
    elif len(raw) > ATTACH_MAX_BYTES:
        why.append(f"the copy is {len(raw) / 1048576:.1f} MB, more than a mail attachment takes "
                   f"({ATTACH_MAX_BYTES // 1048576} MB): it needs another delivery route, and none is built")
    elif hashlib.sha256(raw).hexdigest() != answer.get("sha256"):
        why.append("the file is not the bytes that were recorded")
    else:
        try:
            doc = json.loads(raw)
        except ValueError:
            doc = {}
        if doc.get("kind") != KIND or doc.get("account_id") != answer.get("account_id"):
            why.append("the file is not this account's copy")
        elif not account_email(doc):
            why.append("the account has no sign-in address to send its copy to")
        elif email_now is None:
            why.append("the account's sign-in address could not be read now: a copy is not sent to an address "
                       "nobody has just read")
        elif email_now != account_email(doc):
            why.append("the sign-in address on the account is not the one this copy was built for: rebuild it first")
    if account_now is None or account_now != answer.get("account_id"):
        why.append("the requester does not control this account now (the identity check is re-run before a send)")
    if age_hours > FRESH_HOURS:
        why.append(f"the copy is {age_hours:.0f} h old (limit {FRESH_HOURS} h): rebuild it first")
    return why
