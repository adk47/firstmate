"""Role and name normalization shared by the evidence builder.

Muso credit requests carry display roles ("Mixing", "Immersive Mastering"),
while trusted raw credits carry source vocabulary ("mixing engineer", "mixer",
"composerlyricist"). Both map onto one small set of role FAMILIES so a claim
can be compared with what Spotify / Tidal / MLC / Jaxsta say about the track.
"""

from __future__ import annotations

import re
import unicodedata

# Families where a track normally has exactly ONE credited person. A trusted
# source naming someone else (and not the claimant) is a contradiction. This
# matches IDP #1686's review_role_credited_to_other_at_trusted_source scope.
# "remix" is one of them, but its own family: a remixer and the mix engineer
# do different jobs, so a trusted "Remixer: DJ X" never contradicts a "Mixing"
# claim (or the reverse); another trusted remixer still contradicts a Remixer
# claim, and every one-person guard treats a Remixer claim as it did a mix.
# Parity with core-backend's roleFamilies.js (verifier-core-b1): same remix
# rule (a word-start "re[- ]?mix", checked first) and same test vectors.
ONE_PERSON_FAMILIES = frozenset({"mix", "remix", "master", "immersive_mix", "immersive_master", "remaster"})

# Families that are not personal credits at all (an organisation or a
# rights holder), so they are never compared with a person's claim.
NON_PERSON_FAMILIES = frozenset({"org"})

# Raw-credit sources we treat as independent of the claimant: an explicit
# ALLOWLIST (QA on hydra#1142). Anything else, including "muso" (assertions made
# on Muso itself, often by the claimant), "user_import" or a source added later,
# never counts as corroboration or as a trusted identity anchor.
TRUSTED_SOURCES = frozenset({"spotify", "tidal", "mlc", "jaxsta"})


def is_trusted_source(source: str) -> bool:
    return (source or "").strip().lower() in TRUSTED_SOURCES


_TERM = re.compile(r"[a-z]+(?: [a-z]+)*")


def editorial_terms(value: object) -> tuple[str, ...]:
    """The editorial_role_terms list of policies/credit-trust-decide.json,
    validated. Shared by the decider and uvn-under30, so both refuse the same
    roles; a missing or malformed list is an error, never an empty list."""
    if not isinstance(value, list) or not value:
        raise ValueError("editorial_role_terms must be a non-empty list")
    terms = tuple(t for t in value if isinstance(t, str) and _TERM.fullmatch(t))
    if len(terms) != len(value):
        raise ValueError("editorial_role_terms entries must be lowercase words")
    return terms


def is_editorial(role: str, terms: tuple[str, ...]) -> bool:
    """True when a claimed role is editorial (editing, compilation, assembly,
    ...). A term matches at the start of a word: "edit" matches "Vocal
    Editing" and "Editor", never "Credit"."""
    r = " " + re.sub(r"[^a-z]+", " ", (role or "").lower()).strip()
    return any(" " + t in r for t in terms)


def family_of(role: str) -> str:
    """Map a display role or a raw-credit role string to a role family."""
    r = " " + re.sub(r"[^a-z&]+", " ", (role or "").lower()).strip() + " "
    if not r.strip():
        return "other"
    # First, before the assistant, immersive and mix checks: " remixer "
    # contains "mix", an "Atmos Remix" and an "Assistant Remixer" are still
    # remixes. Word start, so "premix" stays a mix.
    if re.search(r" re ?mix", r):
        return "remix"
    if "assistant" in r or "asst" in r:
        return "assistant"
    if "immersive" in r or "atmos" in r or "spatial" in r:
        if "master" in r:
            return "immersive_master"
        if "mix" in r:
            return "immersive_mix"
    if "remaster" in r:
        return "remaster"
    if "master" in r:
        return "master"
    if "mix" in r:
        return "mix"
    if "executive" in r:
        return "exec_producer"
    if "produc" in r:
        return "producer"
    if any(k in r for k in (" composer", "lyricist", "writer", " author", "composerlyricist", "songwriter")):
        return "writer"
    if "a&r" in r or " a r " in r or r.strip() == "ar":
        return "anr"
    if "arrang" in r:
        return "arranger"
    if any(k in r for k in ("engineer", "recorder", "recorded", "recording", "tracking", "editing", "editor")):
        return "engineer"
    if any(k in r for k in ("primary artist", "main artist", "featured", "featuring")):
        return "artist"
    if any(k in r for k in ("publisher", "label", "copyright", "administrator", "distributor")):
        return "org"
    if "programm" in r:
        return "programming"
    return "performer"


_SPACE = re.compile(r"\s+")


def fold(text: str) -> str:
    """Lowercase, strip accents and punctuation, collapse whitespace."""
    t = unicodedata.normalize("NFKD", text or "")
    t = "".join(ch for ch in t if not unicodedata.combining(ch))
    t = re.sub(r"[^0-9a-zA-Z]+", " ", t).lower()
    return _SPACE.sub(" ", t).strip()


def name_key(text: str) -> frozenset[str]:
    """Order-insensitive token set ("Ghenea Serban" == "Serban Ghenea")."""
    return frozenset(tok for tok in fold(text).split() if tok)


def names_match(a: str, b: str) -> bool:
    """True when two person names plausibly denote the same credit name.

    Exact token-set equality, or one name's tokens fully contained in the
    other's when the shorter side still has two or more tokens ("Jon Castelli"
    vs "Jon P Castelli"). A single shared first name never matches.
    """
    ka, kb = name_key(a), name_key(b)
    if not ka or not kb:
        return False
    if ka == kb:
        return True
    small, big = (ka, kb) if len(ka) <= len(kb) else (kb, ka)
    return len(small) >= 2 and small <= big
