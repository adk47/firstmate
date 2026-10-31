"""Filed document bytes, stored once, by sha256 (Fable 10-31, after the support@ Gmail 429 storm).

The rule: the reader NEVER re-downloads a filed attachment.
- **Filing time:** the filer stores the bytes it already holds (`gmail_intake` for support@ email). Before this,
  a `gmail:<id>` filing kept no bytes, so every read pulled the whole message from Gmail. On 10-30 the carried
  re-read loop pulled 4 filings 2,019 times in 8 h and held support@ at 429 for 9 h.
- **Read time:** a re-read reads the stored bytes. A sha256 mismatch counts as no blob; it is never "close enough".
- **Missing bytes:** a deleted blob does not trigger a re-fetch. Bytes missing for a Gmail filing are restored only
  by `credit-doc-verify.py blob-backfill`. That command is paced, budgeted, takes the shared support@ Gmail lock
  (gmail_intake.gog_raw) and stops on the first quota refusal.

Layout: `<root>/<sha[:2]>/<sha>`, files 0600, dirs 0700, written to a temp name then renamed (a crash never
leaves a partial blob under the final name).
"""

from __future__ import annotations

import hashlib
import os
import re
import tempfile

BLOB_ROOT = os.environ.get("CREDIT_DOC_VERIFY_BLOBS", "/var/lib/hydra-credit-verify/blobs")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


class BlobStore:
    def __init__(self, root: str = BLOB_ROOT):
        self.root = root

    def path(self, sha: str) -> str:
        if not SHA_RE.match(sha or ""):
            raise ValueError("not a sha256")
        return os.path.join(self.root, sha[:2], sha)

    def has(self, sha: str) -> bool:
        """Cheap existence check for selection (the read itself re-hashes with `get`)."""
        try:
            return os.path.isfile(self.path(sha))
        except ValueError:
            return False

    def get(self, sha: str) -> str | None:
        """The stored blob's path when its bytes still hash to `sha`; else None."""
        try:
            p = self.path(sha)
        except ValueError:
            return None
        if not os.path.isfile(p):
            return None
        h = hashlib.sha256()
        try:
            with open(p, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 16), b""):
                    h.update(chunk)
        except OSError:
            return None
        return p if h.hexdigest() == sha else None

    def quarantine(self, sha: str) -> bool:
        """Move a blob whose bytes no longer hash to `sha` aside (`<sha>.corrupt`), so it is owed again and
        restored by blob-backfill (QA #1563). True when a corrupt file was moved."""
        try:
            p = self.path(sha)
        except ValueError:
            return False
        if os.path.isfile(p) and self.get(sha) is None:
            os.replace(p, p + ".corrupt")
            return True
        return False

    def put(self, sha: str, data: bytes) -> str:
        """Store `data` under its sha256 (refused when it does not hash to `sha`); idempotent."""
        if hashlib.sha256(data).hexdigest() != sha:
            raise ValueError("blob bytes do not hash to the filed sha256")
        p = self.path(sha)
        if self.get(sha):
            return p
        d = os.path.dirname(p)
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(self.root, 0o700)
        fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            os.replace(tmp, p)
        except BaseException:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise
        return p
