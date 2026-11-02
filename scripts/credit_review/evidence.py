"""Deterministic evidence for one credit request.

Everything here is computed from core-backend data, with no model involved:

* per claimed role, what the TRUSTED raw credits on the track say (Spotify,
  Tidal, MLC, Jaxsta, i.e. any source except ``muso``): CONFIRMED (they credit
  this profile in that role), CONTRADICTED (a one-person role credited to
  someone else and not to this profile), OTHERS_ONLY (a multi-person role that
  trusted sources list for other people only), or UNVERIFIABLE (no trusted data
  for that role);
* whether the track is BIG, from CATALOG data only (never the request's
  client-sourced popularity): catalog track popularity >= 60, or any track
  artist with catalog popularity >= 90, or any of those unknown/unreadable;
* the claimant's own domains (profile links and raw-profile URLs), which never
  count as independent web evidence;
* identity anchors for the profile (does any trusted-source raw profile link to
  it, or does it exist only on Muso?);
* velocity and the stillfloo fraud signature for the submitting profile.

The judge sees a compact, PII-free rendering of this (``for_model``); the
policy layer decides on the structured fields.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from . import admin as admin_api
from .judge import url_domain
from .roles import (
    NON_PERSON_FAMILIES,
    ONE_PERSON_FAMILIES,
    is_trusted_source,
    family_of,
    names_match,
)

# Same boundaries as the IDP validator.
BIG_TRACK_POPULARITY = 60
BIG_ARTIST_POPULARITY = 90
# Catalog reads per profile velocity scan: the most recent distinct tracks.
VELOCITY_CATALOG_TRACKS = 50


@dataclass(frozen=True)
class TrackCatalog:
    """Catalog popularity of a track and of its linked artists (artists that link a catalog profile)."""
    popularity: int | None
    artist_popularity: int | None   # highest catalog popularity among the track's linked artists
    artists_known: bool             # every linked artist's popularity was read
    artist_read_failed: bool = False  # a linked artist's profile could not be read this run (5xx or 404)
    not_found: bool = False         # the track or a linked artist answered 404 on the re-read too

    @property
    def big(self) -> bool:
        """Unknown counts as big: a failed or missing catalog read must never
        make a track small."""
        return (self.popularity is None or self.popularity >= BIG_TRACK_POPULARITY
                or not self.artists_known or (self.artist_popularity or 0) >= BIG_ARTIST_POPULARITY)


UNKNOWN_TRACK = TrackCatalog(None, None, False)
NOT_FOUND_TRACK = TrackCatalog(None, None, False, not_found=True)


def _int(value: Any) -> int | None:
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _artist_id(artist: Any) -> str:
    if isinstance(artist, str):
        return artist
    if isinstance(artist, dict):
        nested = artist.get("profile") if isinstance(artist.get("profile"), dict) else {}
        return str(artist.get("id") or artist.get("_id") or artist.get("profileId") or nested.get("id") or "")
    return ""


def _urls(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [u for v in value.values() for u in _urls(v)]
    if isinstance(value, list):
        return [u for v in value for u in _urls(v)]
    return []


def claimant_domains(doc: dict[str, Any]) -> list[str]:
    """Registrable domains the claimant controls or is listed on: the
    profile's links and socials and its linked raw profiles' URLs."""
    urls = _urls(doc.get("links")) + _urls(doc.get("socials"))
    urls += [str(rp.get("url") or "") for rp in (doc.get("rawProfiles") or []) if isinstance(rp, dict)]
    return sorted({d for d in (url_domain(u) for u in urls) if d})

class EvidenceIncomplete(admin_api.AdminError):
    """Essential evidence (the track's trusted raw credits) could not be read.

    Classifying against an empty catalog would turn a transient 503 into a
    final UNVERIFIABLE/SUSPECT verdict and hide a real trusted contradiction,
    so the request is not decided at all; callers retry it (QA on hydra#1142).
    """


CONFIRMED = "CONFIRMED"
CONTRADICTED = "CONTRADICTED"
OTHERS_ONLY = "OTHERS_ONLY"
UNVERIFIABLE = "UNVERIFIABLE"


def parse_ts(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


@dataclass
class RoleEvidence:
    claimed_role: str
    family: str
    status: str
    trusted_for_profile: list[dict[str, str]] = field(default_factory=list)
    trusted_for_others: list[dict[str, str]] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "claimed_role": self.claimed_role,
            "family": self.family,
            "status": self.status,
            "trusted_for_profile": self.trusted_for_profile[:5],
            "trusted_for_others": self.trusted_for_others[:8],
        }


@dataclass
class ProfileSignals:
    profile_id: str
    name: str
    aka: list[str]
    trusted_anchor_sources: list[str]
    muso_only: bool
    credit_count: int | None
    popularity: int | None
    primary_genre: str | None
    country: str | None
    years_active: int | None
    is_claimed: bool | None
    created_at: str | None
    requests_24h: int = 0
    requests_7d: int = 0
    big_share_7d: float = 0.0
    one_person_share_7d: float = 0.0
    distinct_lead_artists_7d: int = 0
    window_truncated: bool = False
    velocity_distinct_tracks_7d: int = 0
    velocity_sample_tracks: int = 0
    velocity_error: str | None = None
    prior_contradicted: int = 0

    @property
    def high_velocity(self) -> bool:
        return self.requests_24h >= 50 or self.requests_7d >= 150

    @property
    def stillfloo_pattern(self) -> bool:
        """The 2026 stillfloo signature: a Muso-only identity spraying
        one-person engineering claims across many unrelated big tracks."""
        return (
            self.muso_only
            and self.requests_7d >= 20
            and self.big_share_7d >= 0.30
            and self.distinct_lead_artists_7d >= 10
            and self.one_person_share_7d >= 0.40
        ) or self.prior_contradicted >= 3

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "also_known_as": self.aka[:5],
            "trusted_identity_sources": self.trusted_anchor_sources,
            "muso_only_identity": self.muso_only,
            "credit_count": self.credit_count,
            "popularity": self.popularity,
            "primary_genre": self.primary_genre,
            "country": self.country,
            "years_active": self.years_active,
            "requests_last_24h": self.requests_24h,
            "requests_last_7d": self.requests_7d,
            "share_of_7d_requests_on_big_tracks": round(self.big_share_7d, 2),
            "share_of_7d_requests_one_person_roles": round(self.one_person_share_7d, 2),
            "distinct_lead_artists_7d": self.distinct_lead_artists_7d,
            "velocity_counts_are_a_floor_or_sample": self.window_truncated,
            "velocity_distinct_tracks_7d": self.velocity_distinct_tracks_7d,
            "velocity_big_share_sample_tracks": self.velocity_sample_tracks,
            "prior_contradicted_reviews": self.prior_contradicted,
            "high_velocity": self.high_velocity,
            "stillfloo_like_pattern": self.stillfloo_pattern,
        }


@dataclass
class Evidence:
    request_id: str
    status: str
    profile_id: str
    track_id: str
    track_title: str
    track_artists: list[str]
    catalog: TrackCatalog
    release_date: str | None
    label: str | None
    isrc: str | None
    claimed_roles: list[str]
    validator_approved: bool | None
    validator_risk: float | None
    validator_rules: dict[str, Any]
    approved_at: str | None
    created_at: str | None
    roles: list[RoleEvidence]
    profile: ProfileSignals | None
    raw_credit_count: int = 0
    errors: list[str] = field(default_factory=list)
    claimant_domains: list[str] | None = None   # None: the claimant profile was unreadable
    claimant_names: list[str] = field(default_factory=list)
    catalog_not_found: bool = False   # a catalog read (track, linked artist, claimant) answered 404 twice

    @property
    def track_popularity(self) -> int | None:
        return self.catalog.popularity

    @property
    def artist_popularity(self) -> int | None:
        return self.catalog.artist_popularity

    @property
    def big_track(self) -> bool:
        return self.catalog.big

    def statuses(self) -> list[str]:
        return [r.status for r in self.roles]

    @property
    def any_contradicted(self) -> bool:
        return any(r.status == CONTRADICTED for r in self.roles)

    @property
    def all_confirmed(self) -> bool:
        return bool(self.roles) and all(r.status == CONFIRMED for r in self.roles)

    @property
    def any_others_only(self) -> bool:
        return any(r.status == OTHERS_ONLY for r in self.roles)

    def deterministic_summary(self) -> str:
        parts = [f"{r.claimed_role}={r.status}" for r in self.roles]
        return ",".join(parts) or "no_roles"

    def for_model(self) -> dict[str, Any]:
        """PII-free view for the model: public catalogue facts only. No emails,
        user ids, workspace names or internal ids beyond the track's ISRC."""
        return {
            "claim": {
                "person_or_profile_name": self.profile.name if self.profile else None,
                "claimed_roles": self.claimed_roles,
            },
            "track": {
                "title": self.track_title,
                "artists": self.track_artists,
                "isrc": self.isrc,
                "label": self.label,
                "release_date": self.release_date,
                "catalog_popularity": self.track_popularity,
                "max_artist_popularity": self.artist_popularity,
                "big_track": self.big_track,
            },
            "trusted_catalog_credits_by_role": [r.as_dict() for r in self.roles],
            "profile": self.profile.as_dict() if self.profile else None,
            "rule_validator": {
                "approved": self.validator_approved,
                "total_risk_percent": self.validator_risk,
            },
        }


def _raw_name(raw: dict[str, Any]) -> str:
    prof = raw.get("profile") or {}
    return str(prof.get("name") or "")


def _raw_source(raw: dict[str, Any]) -> str:
    prof = raw.get("profile") or {}
    return str(prof.get("source") or "").lower()


def _raw_key(raw: dict[str, Any]) -> tuple[str, str]:
    prof = raw.get("profile") or {}
    return (str(prof.get("source") or "").lower(), str(prof.get("id") or ""))


def classify_roles(
    claimed_roles: list[str],
    raw_credits: list[dict[str, Any]],
    profile_names: list[str],
    profile_raw_keys: set[tuple[str, str]],
) -> list[RoleEvidence]:
    """Compare each claimed role with the track's trusted raw credits."""

    def is_profile(raw: dict[str, Any]) -> bool:
        if _raw_key(raw) in profile_raw_keys:
            return True
        name = _raw_name(raw)
        return any(names_match(name, n) for n in profile_names if n)

    out: list[RoleEvidence] = []
    for claimed in claimed_roles:
        fam = family_of(claimed)
        mine: list[dict[str, str]] = []
        others: list[dict[str, str]] = []
        if fam not in NON_PERSON_FAMILIES:
            for raw in raw_credits:
                src = _raw_source(raw)
                if not is_trusted_source(src):
                    continue
                raw_role = str(raw.get("credit") or "")
                if family_of(raw_role) != fam:
                    continue
                row = {"source": src, "name": _raw_name(raw), "role": raw_role}
                (mine if is_profile(raw) else others).append(row)
        if mine:
            status = CONFIRMED
        elif others and fam in ONE_PERSON_FAMILIES:
            status = CONTRADICTED
        elif others:
            status = OTHERS_ONLY
        else:
            status = UNVERIFIABLE
        out.append(RoleEvidence(claimed, fam, status, mine, others))
    return out


class EvidenceBuilder:
    """Builds Evidence with per-run caches so a batch of requests from one
    profile costs one profile read and one velocity scan, not N."""

    def __init__(self, admin: admin_api.Admin, *, now: datetime | None = None,
                 prior_contradicted: dict[str, int] | None = None,
                 velocity_pages: int = 1, always_velocity: bool = False):
        self.admin = admin
        self.now = now or datetime.now(timezone.utc)
        self.prior_contradicted = prior_contradicted or {}
        self.velocity_pages = velocity_pages
        self.always_velocity = always_velocity
        self._profiles: dict[str, dict[str, Any] | None] = {}
        self._not_found: set[str] = set()   # ids that answered 404 twice this run
        self._signals: dict[str, ProfileSignals] = {}
        self._raw: dict[str, list[dict[str, Any]]] = {}
        self._tracks: dict[str, tuple[TrackCatalog, str | None]] = {}
        # (doc, read error, was 404): ONE admin track read per track per run, shared by
        # track_catalog (popularity) and the label/P-line consumer. Two caches bought two
        # identical GETs per track, which is a fifth of a V9 run's admin budget.
        self._track_docs: dict[str, tuple[dict[str, Any] | None, str | None, bool]] = {}
        self._velocity_done: set[str] = set()
        self._locks_guard = threading.Lock()
        self._profile_locks: dict[str, threading.Lock] = {}

    def _profile_lock(self, profile_id: str) -> threading.Lock:
        """build() runs in parallel; one lock per profile makes every request
        of that profile share one fully computed ProfileSignals."""
        with self._locks_guard:
            return self._profile_locks.setdefault(profile_id, threading.Lock())

    # -- cached reads -------------------------------------------------------
    def _reread(self, fn: Any, record_id: str) -> Any:
        """One read, and ONE re-read on a 404 (core-backend answers 404 for a
        failed catalog read as well as for a missing record). A second 404 is
        remembered and propagates."""
        try:
            return fn(self.admin, record_id)
        except admin_api.NotFound:
            try:
                return fn(self.admin, record_id)
            except admin_api.NotFound:
                self._not_found.add(record_id)
                raise

    def raw_credits(self, track_id: str) -> list[dict[str, Any]]:
        if track_id not in self._raw:
            self._raw[track_id] = self._reread(admin_api.track_raw_credits, track_id)
        return self._raw[track_id]

    def profile_doc(self, profile_id: str) -> dict[str, Any] | None:
        if profile_id not in self._profiles:
            try:
                self._profiles[profile_id] = self._reread(admin_api.profile, profile_id)
            except admin_api.AdminError:
                self._profiles[profile_id] = None
        return self._profiles[profile_id]

    def _track_read(self, track_id: str) -> tuple[dict[str, Any] | None, str | None, bool]:
        """(doc, read error, was 404) for one track, read ONCE per run. Both failure kinds are
        cached, and they stay distinct: a 404 is NOT_FOUND_TRACK, anything else UNKNOWN_TRACK."""
        if track_id not in self._track_docs:
            try:
                self._track_docs[track_id] = (self._reread(admin_api.track, track_id), None, False)
            except admin_api.NotFound as exc:
                self._track_docs[track_id] = (None, f"track {track_id}: 404 on the re-read too: {exc}", True)
            except admin_api.AdminError as exc:
                self._track_docs[track_id] = (None, f"track {track_id}: {exc}", False)
        return self._track_docs[track_id]

    def track_doc(self, track_id: str) -> dict[str, Any] | None:
        """The raw admin track document (label / P-line fields). Shares `_track_read` with
        track_catalog, so a run costs one GET per track, not one per consumer."""
        if not track_id:
            return None
        return self._track_read(track_id)[0]

    def track_catalog(self, track_id: str) -> tuple[TrackCatalog, str | None]:
        """(catalog popularity of the track and its artists, read error)."""
        if not track_id:
            return UNKNOWN_TRACK, "track: no trackId"
        if track_id not in self._tracks:
            doc, err, not_found = self._track_read(track_id)
            if doc is None:
                self._tracks[track_id] = (NOT_FOUND_TRACK if not_found else UNKNOWN_TRACK, err)
            else:
                self._tracks[track_id] = (self._catalog_of(doc), None)
        return self._tracks[track_id]

    def _catalog_of(self, doc: dict[str, Any]) -> TrackCatalog:
        """Same rule as the IDP's _is_big_track (industry-data-processing
        credit_validation_rules.py): unknown TRACK popularity is big; only the
        artists that link a catalog profile are checked; a track with no linked
        artist is decided by its own popularity (not big below 60); a linked
        artist whose popularity cannot be read is unknown, so big. Before this
        (Fable credit-AI report, 10-14) an unlinked artist made the track big:
        35 of 89 model calls that day were on pop-0/1 tracks the IDP calls small."""
        artists = doc.get("artists") if isinstance(doc.get("artists"), list) else []
        ids = list(dict.fromkeys(filter(None, (_artist_id(a) for a in artists))))
        known = True
        failed = False
        pops: list[int] = []
        for aid in filter(None, ids):
            artist = self.profile_doc(aid)
            failed = failed or artist is None
            pop = _int((artist or {}).get("popularity"))
            if pop is None:
                known = False
            else:
                pops.append(pop)
        return TrackCatalog(_int(doc.get("popularity")), max(pops) if pops else None, known, failed,
                            bool(self._not_found.intersection(ids)))

    def profile_signals(self, profile_id: str, fallback: dict[str, Any]) -> ProfileSignals:
        with self._profile_lock(profile_id):
            return self._profile_signals(profile_id, fallback)

    def _profile_signals(self, profile_id: str, fallback: dict[str, Any]) -> ProfileSignals:
        if profile_id in self._signals:
            return self._signals[profile_id]
        doc = self.profile_doc(profile_id) or {}
        raw_profiles = doc.get("rawProfiles") if isinstance(doc.get("rawProfiles"), list) else []
        anchors = sorted({str(rp.get("source") or "").lower() for rp in raw_profiles
                          if is_trusted_source(str(rp.get("source") or ""))})
        aka = [str(a) for a in (doc.get("knownAsNames") or []) if a]
        sig = ProfileSignals(
            profile_id=profile_id,
            name=str(doc.get("name") or fallback.get("name") or ""),
            aka=aka,
            trusted_anchor_sources=anchors,
            muso_only=not anchors,
            credit_count=doc.get("creditCount", fallback.get("creditCount")),
            popularity=doc.get("popularity", fallback.get("popularity")),
            primary_genre=doc.get("primaryGenre"),
            country=doc.get("country"),
            years_active=doc.get("yearsActive"),
            is_claimed=doc.get("isClaimed"),
            created_at=doc.get("createdAt"),
            prior_contradicted=self.prior_contradicted.get(profile_id, 0),
        )
        self._signals[profile_id] = sig
        return sig

    def ensure_velocity(self, sig: ProfileSignals) -> None:
        """Velocity costs a few list reads per profile, so it runs only for
        requests the catalog could not decide (and once per profile per run)."""
        with self._profile_lock(sig.profile_id):
            if sig.profile_id in self._velocity_done:
                return
            self._velocity(sig)
            self._velocity_done.add(sig.profile_id)

    def _velocity(self, sig: ProfileSignals) -> None:
        """Requests this profile created in the last 24h / 7d, across statuses.

        Reads the newest page(s) per status (the list is updatedAt DESC). When a
        full page is still inside the 7d window the counts are a floor, and
        ``window_truncated`` says so. A failed read is recorded in
        ``velocity_error`` (an evidence error), never read as zero requests.
        The big-track share reads the catalog for at most
        VELOCITY_CATALOG_TRACKS distinct tracks: past that, an evenly spaced
        sample across the week's distinct tracks (oldest to newest, first and
        last included), which submission order cannot steer, and
        ``window_truncated`` is set.
        """
        day_ago = self.now - timedelta(days=1)
        week_ago = self.now - timedelta(days=7)
        seen: set[str] = set()
        rows: list[dict[str, Any]] = []
        for status in ("approved", "unverified", "user_verification_needed"):
            for page in range(1, self.velocity_pages + 1):
                try:
                    items = admin_api.list_requests(self.admin, status=status, limit=500, page=page,
                                                    profile_ids=[sig.profile_id])
                except admin_api.AdminError as exc:
                    sig.velocity_error = f"velocity ({status} page {page}): {exc}"
                    break
                for it in items:
                    rid = str(it.get("id"))
                    if rid not in seen:
                        seen.add(rid)
                        rows.append(it)
                if len(items) < 500:
                    break
                last = parse_ts(items[-1].get("updatedAt"))
                if last and last < week_ago:
                    break
                if page == self.velocity_pages:
                    sig.window_truncated = True
        week = [r for r in rows if (parse_ts(r.get("createdAt")) or datetime.min.replace(tzinfo=timezone.utc)) >= week_ago]
        sig.requests_7d = len(week)
        sig.requests_24h = sum(1 for r in week if (parse_ts(r.get("createdAt")) or week_ago) >= day_ago)
        if week:
            oldest = sorted(week, key=lambda r: str(r.get("createdAt") or ""))
            tracks = list(dict.fromkeys(str(r.get("trackId") or "") for r in oldest))
            n, k = len(tracks), VELOCITY_CATALOG_TRACKS
            if n > k:
                sig.window_truncated = True
                tracks = [tracks[round(i * (n - 1) / (k - 1))] for i in range(k)]
            checked = set(tracks)
            sig.velocity_distinct_tracks_7d = n
            sig.velocity_sample_tracks = len(checked)
            sample = [r for r in week if str(r.get("trackId") or "") in checked]
            big = sum(1 for r in sample if self.track_catalog(str(r.get("trackId") or ""))[0].big)
            sig.big_share_7d = big / len(sample)
            one = sum(1 for r in week if any(family_of(c) in ONE_PERSON_FAMILIES for c in (r.get("credits") or [])))
            sig.one_person_share_7d = one / len(week)
            leads = {str((r.get("spotifyTrackArtists") or [{}])[0].get("name") or "").lower() for r in week}
            leads.discard("")
            sig.distinct_lead_artists_7d = len(leads)

    # -- build --------------------------------------------------------------
    def build(self, request: dict[str, Any]) -> Evidence:
        errors: list[str] = []
        vd = request.get("verificationData") if isinstance(request.get("verificationData"), dict) else {}
        meta = request.get("metadata") if isinstance(request.get("metadata"), dict) else {}
        profile_id = str(request.get("profileId") or "")
        track_id = str(request.get("trackId") or "")
        claimed = [str(c) for c in (request.get("credits") or []) if c]

        signals: ProfileSignals | None = None
        try:
            signals = self.profile_signals(profile_id, request.get("profile") or {})
        except admin_api.AdminError as exc:
            errors.append(f"profile: {exc}")

        raw: list[dict[str, Any]] = []
        try:
            raw = self.raw_credits(track_id) if track_id else []
        except admin_api.AdminError as exc:
            raise EvidenceIncomplete(f"raw_credits for track {track_id}: {exc}") from exc

        claimant_doc = self.profile_doc(profile_id)
        if claimant_doc is None:
            errors.append(f"claimant profile {profile_id}: unreadable, claimant domains unknown")
        doc = claimant_doc or {}
        names = [signals.name if signals else str((request.get("profile") or {}).get("name") or "")]
        names += [str(a) for a in (doc.get("knownAsNames") or []) if a]
        if doc.get("legalName"):
            names.append(str(doc["legalName"]))
        if doc.get("firstName") and doc.get("lastName"):
            names.append(f"{doc['firstName']} {doc['lastName']}")
        raw_keys = {(str(rp.get("source") or "").lower(), str(rp.get("id") or ""))
                    for rp in (doc.get("rawProfiles") or []) if isinstance(rp, dict)}

        catalog, track_error = self.track_catalog(track_id)
        if track_error:
            errors.append(track_error)

        roles = classify_roles(claimed, raw, names, raw_keys)
        # Velocity is skipped only when a trusted contradiction already decides
        # the row against the claim. A CONFIRMED row still needs it: the review
        # clamp turns a confirmation on a stillfloo-pattern profile into
        # NEEDS-HUMAN, and it can only see a pattern that velocity computed
        # (QA on hydra#1142).
        contradicted = any(r.status == CONTRADICTED for r in roles)
        if signals is not None and (self.always_velocity or not contradicted):
            self.ensure_velocity(signals)
            if signals.velocity_error:
                errors.append(signals.velocity_error)
        risk = vd.get("total_risk_percent")
        return Evidence(
            request_id=str(request.get("id") or ""),
            status=str(request.get("status") or ""),
            profile_id=profile_id,
            track_id=track_id,
            track_title=str(request.get("spotifyTrackTitle") or ""),
            track_artists=[str(a.get("name") or "") for a in (request.get("spotifyTrackArtists") or []) if isinstance(a, dict)],
            catalog=catalog,
            release_date=meta.get("releaseDate"),
            label=meta.get("label"),
            isrc=meta.get("isrc"),
            claimed_roles=claimed,
            validator_approved=vd.get("is_approved") if isinstance(vd.get("is_approved"), bool) else None,
            validator_risk=float(risk) if isinstance(risk, (int, float)) else None,
            validator_rules=vd.get("rule_risk_percent") if isinstance(vd.get("rule_risk_percent"), dict) else {},
            approved_at=request.get("updatedAt") if request.get("status") == "approved" else None,
            created_at=request.get("createdAt"),
            roles=roles,
            profile=signals,
            raw_credit_count=len(raw),
            errors=errors,
            claimant_domains=claimant_domains(doc) if claimant_doc is not None else None,
            claimant_names=[n for n in names if n],
            catalog_not_found=catalog.not_found or (claimant_doc is None and profile_id in self._not_found),
        )
