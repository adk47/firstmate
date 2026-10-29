"""F2 reuse and F2b template families: sha256, perceptual hash, text MinHash.

Calibrated on the real 90-day proof set (report §8): perceptual hash at
Hamming <= 6 matched 13 unrelated pairs of screenshots (layout coincidences)
and <= 2 matched none, so images use <= 2. Documents are compared by a MinHash
of 5-word shingles of their text PLUS their entities (ISRCs, ISWCs, name
hashes, share percentages): a blank split-sheet template filled in by two
different people shares its text but not its entities - that is a template
family (info), not reuse. Name hashes leave out form headings ("Song Title",
"Writer Name", content.FORM_WORDS), so a long template's own Title-Case
labels never count as shared names. Only another account's reuse counts; the
same contact re-uploading is ignored.
"""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass, field
from typing import Any

from credit_review.roles import fold

PHASH_MAX_DISTANCE = 2
MINHASH_PERMS = 64
MINHASH_MIN_SHINGLES = 20
MINHASH_REUSE = 0.85
# Same template, different content (a blank form filled in by different people).
MINHASH_FAMILY = 0.45


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def phash64(png: bytes) -> int:
    """DCT perceptual hash (32x32 grey, top-left 8x8 without DC vs median).
    Raises when numpy/Pillow are missing or the image does not decode: the
    caller records that as an error (near-duplicate matching could not run)."""
    import numpy as np
    from PIL import Image
    with Image.open(io.BytesIO(png)) as im:
        g = np.asarray(im.convert("L").resize((32, 32), Image.LANCZOS), dtype=np.float64)
    n = 32
    k = np.arange(n)
    basis = np.cos(np.pi * (2 * k[None, :] + 1) * k[:, None] / (2 * n))
    dct = basis @ g @ basis.T
    low = dct[:8, :8].flatten()[1:]
    med = np.median(low)
    bits = 0
    for v in low:
        bits = (bits << 1) | int(v > med)
    return bits


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def shingles(text: str, k: int = 5) -> set[str]:
    words = fold(text).split()
    return {" ".join(words[i:i + k]) for i in range(max(0, len(words) - k + 1))}


def text_sha(text: str) -> str | None:
    """EXACT normalized-text identity (Fable b1 on #1514): sha256 of the folded text with whitespace collapsed; None
    when there is no text. MinHash is similarity, never equality."""
    norm = " ".join(fold(text or "").split())
    return hashlib.sha256(norm.encode()).hexdigest() if norm else None


def minhash(sh: set[str]) -> list[int]:
    if not sh:
        return []
    out = []
    for i in range(MINHASH_PERMS):
        salt = i.to_bytes(4, "big")
        out.append(min(int.from_bytes(hashlib.blake2b(s.encode(), digest_size=8, salt=salt).digest(), "big") for s in sh))
    return out


def jaccard(a: list[int], b: list[int]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    return sum(x == y for x, y in zip(a, b)) / len(a)


@dataclass
class Fingerprint:
    proof_id: str                   # sha256 of the bytes
    contact_h: str                  # hashed submitter (Intercom contact / Muso user); "" = unknown
    kind: str
    mime: str
    phash: int | None = None
    minhash: list[int] = field(default_factory=list)
    n_shingles: int = 0
    entities: dict[str, Any] = field(default_factory=dict)
    track_key: str | None = None
    role_families: list[str] = field(default_factory=list)       # role families the submitter claims
    claimant_named: bool | None = None                           # F5b: submitter named in the document (None = not checked)
    track_listed: bool | None = None                             # F5a: submitter's track title/ISRC in it (None = not checked)
    name_h: str | None = None                                    # content.name_hash of the credited name matched
    text_sha: str | None = None                                  # text_sha() of the extracted text (None = unknown)
    name_verified: bool | None = None                            # that name came from verified_names

    @property
    def document_roles(self) -> set[str]:
        """Role families the document itself lists (content.entities)."""
        return set((self.entities or {}).get("roles") or [])

    def entity_overlap(self, other: Fingerprint) -> list[str]:
        why = []
        a, b = self.entities or {}, other.entities or {}
        if set(a.get("isrcs") or []) & set(b.get("isrcs") or []):
            why.append("isrc")
        if set(a.get("iswcs") or []) & set(b.get("iswcs") or []):
            why.append("iswc")
        if len(set(a.get("name_hashes") or []) & set(b.get("name_hashes") or [])) >= 3:
            why.append("names")
        if a.get("percent_sig") and a.get("percent_sig") == b.get("percent_sig") and a["percent_sig"].count(",") >= 1:
            why.append("shares")
        return why
