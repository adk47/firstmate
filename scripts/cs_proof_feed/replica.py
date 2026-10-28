"""Read-only core-replica lookup for the proof-on-file feed, from node-8.

The feed used to run on the captain's Mac and reached the replica through node-1
(`ssh ubuntu@10.0.0.19 sudo -u postgres psql`). node-8 has no ssh key for the
replica host, but it has the Trino wrapper (scripts/trino-query.sh -> kubectl exec
trino-coordinator), so the SAME Postgres statement runs as a `postgresql_core`
passthrough: `TABLE(postgresql_core.system.query(query => '...'))`. The statement is
pushed to Postgres verbatim, so `lower(email)` uses the replica's own index exactly
like the psql path did. Read-only by construction: the passthrough only accepts a
SELECT, and the connector user is the replica's read-only role.

Emails are only ever held in memory; nothing here writes them anywhere.
"""
import csv
import io
import os
import subprocess

TRINO = os.environ.get("CS_PROOF_TRINO", "/opt/hydra/scripts/trino-query.sh")
CHUNK = 500


def _ok(addr):
    # The statement is built by string, so refuse anything that could break out of the
    # two levels of quoting (the Postgres literal inside the Trino literal).
    return bool(addr) and "'" not in addr and "\\" not in addr and "\n" not in addr


def build_sql(chunk):
    pg = ("SELECT lower(email) AS email, id FROM users WHERE lower(email) IN ("
          + ",".join("'" + e + "'" for e in chunk) + ")")
    # Trino string literal: double every single quote of the inner statement.
    return ("SET SESSION query_max_execution_time='120s'; "
            "SELECT email, cast(id as varchar) FROM TABLE(postgresql_core.system.query(query => '"
            + pg.replace("'", "''") + "'))")


def parse(stdout):
    """{email: user_id} from the wrapper's CSV. Non-data lines (JVM banner, warnings)
    are mixed into stdout by the wrapper; every data line is a quoted CSV row."""
    out = {}
    rows = csv.reader(io.StringIO("\n".join(l for l in stdout.splitlines() if l.startswith('"'))))
    for r in rows:
        if len(r) >= 2 and r[1].isdigit():
            out[r[0]] = int(r[1])
    return out


def users_by_email(addresses, run=subprocess.run):
    """{lower(email): users.id} for every address that has a Muso account.
    Raises RuntimeError when a chunk cannot be read (callers fail closed)."""
    emails = sorted({a.strip().lower() for a in addresses if _ok(a)})
    out = {}
    for i in range(0, len(emails), CHUNK):
        p = run([TRINO], input=build_sql(emails[i:i + CHUNK]), capture_output=True, text=True, timeout=300)
        if p.returncode != 0:
            raise RuntimeError("core lookup failed: " + (p.stderr or p.stdout or "")[-300:])
        out.update(parse(p.stdout))
    return out


_ISO = __import__("re").compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def users_created_since(iso, run=subprocess.run):
    """{lower(email): users.id} for accounts created at or after `iso` (ISO 8601 UTC, validated before
    it is put in the statement). Used to attribute proof mail sent BEFORE the sender registered.
    Raises RuntimeError when unreadable (callers fail closed)."""
    if not _ISO.match(iso or ""):
        raise RuntimeError(f"bad timestamp {iso!r}")
    pg = ("SELECT lower(email) AS email, id FROM users WHERE email IS NOT NULL AND \"createdAt\" >= '"
          + iso + "'")
    sql = ("SET SESSION query_max_execution_time='120s'; "
           "SELECT email, cast(id as varchar) FROM TABLE(postgresql_core.system.query(query => '"
           + pg.replace("'", "''") + "'))")
    p = run([TRINO], input=sql, capture_output=True, text=True, timeout=300)
    if p.returncode != 0:
        raise RuntimeError("core lookup failed: " + (p.stderr or p.stdout or "")[-300:])
    return parse(p.stdout)
