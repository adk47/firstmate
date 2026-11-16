"""The claim forms: the four ways a claim can be settled, which of them settles which class, and the
one check each form gets.

A claim is proved by a form. Until 2026-11-16 the claim ladder knew exactly one (a document), so a
claimant who had no paperwork could only be asked for paperwork: 8,167 of the 9,147 documents on
the credit side were credits pages, and 0 of them verified. The captain's ruling the same day:

  "every row ends ASK (one specific ask) or NO ... escalation may be by email address, phone
   number or collaborator proof from an existing Muso user"

THE FOUR FORMS, and the one verdict each can reach on its own:

  document          what the ladder already reads: a document that names the claimant and the
                    profile (doc_ladder). Nothing here changes it.
  email_address     the claimant ACCOUNT's own address (core's users.email, read with the claim)
                    at a host the profile itself publishes (the website on the profile). The account
                    signed up with that mailbox, so the address is a mailbox the claimant holds -
                    which is what an organisation claim needs. A typed address at a published domain
                    proves nothing on its own: anyone can type one, and no message is sent from here.
  phone_number      a number the profile publishes. NO SOURCE PUBLISHES ONE TO US TODAY (core holds
                    no profile phone and no page reader here fetches page text): `FORMS_WITHOUT_A_SOURCE`
                    names it, `check` refuses it as such (a measured NO, never a wait) and
                    `checkable` keeps it from ever being offered.
  collaborator_proof  another Muso user crediting the claimant on a release they share. RECOGNISED,
                    RECORDED AND RESERVED: nothing here can ask that user to confirm it, and a public
                    profile id anyone could paste is not their word, so `FORMS_WITHOUT_A_CHECK`
                    keeps it from being offered or settling anything until an attestation channel
                    exists. Its facts are kept PER REF for that day.

THE RULE THIS TABLE ENFORCES (captain, same ruling): an offer we cannot check is worse than no
offer. So `offered()` only ever names a form whose facts were READ (`checkable`), and the document
is the last rung of every ordering: a claim is always left with an ask it can answer.

UNMEASURED IS NOT A REFUSAL. A check whose facts could not be read returns `ok=False`? Never:
it returns `ok=None`, which the ladder turns into `awaiting_read` naming the job that owes the read
(`doc_ladder.ROUTES["doc-sources"]`), and the claimant is asked for nothing while the fact is
unread.

NOTHING HERE SENDS, DECIDES OR WRITES. It is a pure function of (form, value, delivered facts), so
a recorded decision can be re-derived and must come out the same.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from claim_verify import bound_pages
from lib import page_identity

FORM_DOCUMENT = "document"
FORM_EMAIL = "email_address"
FORM_PHONE = "phone_number"
FORM_COLLABORATOR = "collaborator_proof"
FORMS = (FORM_DOCUMENT, FORM_EMAIL, FORM_PHONE, FORM_COLLABORATOR)

# A form no source can check yet. Supplying one is a measured NO - the check cannot be satisfied,
# so it is `ok=False` with this reason and the ladder refuses with the ask that CAN still settle the
# claim - not a wait. `checkable` is false for these, so they are never offered either.
# The forms nothing here can check yet, and the reason each one names. A supplied one is a measured
# NO (never a wait), it is never offered, and its words live in `reserved_form_asks` rather than in an
# ask the ladder can deliver.
#   phone_number        no source publishes a profile phone to us
#   collaborator_proof  no channel exists to ask the collaborator to confirm, and a public profile id
#                       anybody could paste is not that user's word
FORMS_WITHOUT_A_CHECK = {FORM_PHONE: "no_source_can_check_this_form",
                         FORM_COLLABORATOR: "collaborator_attestation_not_recorded"}
FORMS_WITHOUT_A_SOURCE = tuple(FORMS_WITHOUT_A_CHECK)      # the older name, kept for its readers

# The forms that can settle a claim of each class, best first. The document leads everywhere (it is
# the evidence the ladder already reads end to end); a class the policy does not name gets the
# document alone, because no other check was ever reviewed for it.
SETTLES: dict[str, tuple[str, ...]] = {
    "artist": (FORM_DOCUMENT, FORM_COLLABORATOR, FORM_EMAIL),
    "professional": (FORM_DOCUMENT, FORM_COLLABORATOR, FORM_EMAIL),
    "organization": (FORM_DOCUMENT, FORM_EMAIL, FORM_PHONE),
}

# The ask an ask key is delivered in, per claim class, best first. A need a document cannot settle
# for that class names the form that can; every other need stays the document (its bytes unchanged
# in policies/claim-doc-asks.json). `forms_of` reads this table and nothing else.
FORMS_BY_ASK: dict[str, dict[str, tuple[str, ...]]] = {
    # A person with no paperwork: an existing Muso user credited on the same release can say who the
    # claimant is, and the catalog already holds both sides. The document stays as the second rung.
    "proof_naming_claimant": {"artist": (FORM_COLLABORATOR, FORM_DOCUMENT),
                              "professional": (FORM_COLLABORATOR, FORM_DOCUMENT),
                              "organization": (FORM_DOCUMENT,)},
    # The profile's own published domain says who acts for it; a collaborator says who the person is.
    "proof_naming_profile": {"artist": (FORM_COLLABORATOR, FORM_EMAIL, FORM_DOCUMENT),
                             "professional": (FORM_COLLABORATOR, FORM_EMAIL, FORM_DOCUMENT),
                             "organization": (FORM_EMAIL, FORM_DOCUMENT)},
    # "The company's own authorisation, from the company's domain" is a circle when the claimant IS
    # the company: an address at that domain is the authorisation. A published number is the same
    # proof, and is never offered today because nothing publishes one to us.
    "company_authority": {"organization": (FORM_EMAIL, FORM_PHONE, FORM_DOCUMENT),
                          "artist": (FORM_DOCUMENT,), "professional": (FORM_DOCUMENT,)},
}

# The refusal a supplied form that does not settle carries, and the ask it is answered with, by
# class: the same need, offered again in the form that can still settle it.
FORM_REFUSAL_ASKS: dict[str, str] = {
    "artist": "proof_naming_claimant",
    "professional": "proof_naming_claimant",
    "organization": "company_authority",
}

FREE_MAIL = frozenset({
    "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk", "ymail.com", "hotmail.com", "hotmail.co.uk",
    "outlook.com", "outlook.fr", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com",
    "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.de", "gmx.net", "mail.com", "mail.ru",
    "yandex.com", "yandex.ru", "zoho.com", "qq.com", "163.com", "126.com", "web.de", "tutanota.com",
})

# Hosts that are somebody's free account or a link hub, never an organisation's own domain: an
# address at one of these says nothing about who acts for the profile, so it never settles a claim.
# ONE list, read by `check`; adding a host here is the whole change.
SHARED_HOSTS = FREE_MAIL | frozenset({
    "instagram.com", "facebook.com", "fb.com", "threads.net", "tiktok.com", "x.com", "twitter.com",
    "youtube.com", "youtu.be", "soundcloud.com", "spotify.com", "bandcamp.com", "patreon.com",
    "linktr.ee", "linktree.com", "bio.link", "linkin.bio", "beacons.ai", "carrd.co", "about.me",
    "wixsite.com", "squarespace.com", "wordpress.com", "blogspot.com", "medium.com", "behance.net",
    "vk.com", "bit.ly", "tinyurl.com", "linkfly.to", "snipfeed.co", "allmylinks.com",
})

EMAIL = re.compile(r"^[^@\s]+@([a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+)$", re.I)
PHONE = re.compile(r"^\+?[0-9().\-\s]{6,25}$")
PROFILE_REF = re.compile(r"muso\.ai/profile/([0-9a-f]{8}(?:-[0-9a-f]{1,12}){0,4})", re.I)
# A bare id: a uuid, or a truncated one, in the one shape `page_identity` compares. Lower-cased
# first, so this is checked on the comparable spelling and nowhere else.
PROFILE_ID = re.compile(r"^[0-9a-f]{8}(?:-[0-9a-f]{1,12}){0,4}$")
MIN_PHONE_DIGITS, MAX_PHONE_DIGITS = 8, 15      # E.164 allows at most 15


@dataclass(frozen=True)
class Supplied:
    """One form a claimant supplied, and what the check made of it. `ok is None` means the facts
    the check needs were not read: unmeasured, never a pass and never a refusal."""
    form: str
    value: str
    normalised: str
    ok: bool | None
    reason: str
    evidence: dict[str, Any]
    supplied_at: str = ""
    intake_id: str = ""

    @property
    def value_sha256(self) -> str:
        """What was supplied, hashed: the verdict row names the form and this digest. The value
        itself is on the append-only supply row only, and the 0600 snapshot keeps it while a pass
        decides (the stored decision carries the digest, and `verify` re-reads the value from the
        supply row by that digest)."""
        return hashlib.sha256(f"{self.form}|{self.normalised}".encode("utf-8")).hexdigest()


def value_digest(form: str, normalised: str) -> str:
    return hashlib.sha256(f"{form}|{normalised}".encode("utf-8")).hexdigest()


def forms_of(ask: str, claim_class: str) -> tuple[str, ...]:
    """The forms an ask may be delivered in for this class, best first. An ask this table does not
    name, an empty class or an unknown class is delivered as the document: no form is offered for a
    class nothing was reviewed for."""
    by_class = FORMS_BY_ASK.get(ask) or {}
    order = by_class.get((claim_class or "").strip().lower()) or (FORM_DOCUMENT,)
    return tuple(f for f in order if f in SETTLES.get((claim_class or "").strip().lower(), (FORM_DOCUMENT,))) \
        or (FORM_DOCUMENT,)


def checkable(form: str, facts: Mapping[str, Any]) -> bool:
    """Whether this form CAN be checked and the facts it needs were READ for this claim. A form no
    source can check is never checkable, and an unread fact is not either, so neither is ever offered
    (`offered`) nor has words the ladder could deliver (`doc_ladder.check_ask_copy`)."""
    if form == FORM_DOCUMENT:
        return True
    if form in FORMS_WITHOUT_A_CHECK:
        return False
    if form == FORM_EMAIL:
        # offered only where EVERY half of the check was read: the profile publishes a host, the
        # claiming account holds a mailbox core CONFIRMED (a verified address, not a typed one), and
        # that address's domain is one this profile publishes and that say anything (never free mail
        # or a shared platform host). Missing any of them, the ask falls through to the document: a
        # form no answer could satisfy is not an offer.
        hosts = facts.get("profile_hosts")
        digest = facts.get("account_email_sha256")
        domain = facts.get("account_email_domain")
        return (isinstance(hosts, (list, tuple)) and bool(hosts)
                and isinstance(digest, str) and bool(digest.strip())
                and facts.get("account_email_confirmed") is True
                and isinstance(domain, str) and settles_at(domain, hosts))
    if form == FORM_PHONE:
        return isinstance(facts.get("profile_phones"), (list, tuple)) and bool(facts["profile_phones"])
    if form == FORM_COLLABORATOR:
        titles = facts.get("profile_titles")
        return isinstance(titles, (list, tuple)) and bool(titles)
    return False


def settles_at(domain: str, hosts: Iterable[str]) -> bool:
    """Whether an address at this domain is one that could settle a claim for a profile publishing
    `hosts`: a host we can actually read as the organisation's own, matched exactly or by subdomain.
    The offer and the check read the SAME predicate, so a form is never offered over a domain its own
    check would refuse."""
    d = (domain or "").strip().lower()
    if not d or d in FREE_MAIL or _under(d, SHARED_HOSTS):
        return False
    return any(d == h or d.endswith("." + h) for h in hosts if h)


def offered(ask: str, claim_class: str, facts: Mapping[str, Any] | None,
            exclude: tuple[str, ...] = ()) -> str:
    """The ONE form the ladder asks this claim's ask in: the first in `forms_of` whose facts were
    read. `exclude` names a form the claimant already supplied and that did not settle, so the same
    form is never asked for twice. The document is the last rung of every ordering, so this always
    names a form the claimant can answer in."""
    for form in forms_of(ask, claim_class):
        if form in exclude:
            continue
        if checkable(form, facts or {}):
            return form
    return FORM_DOCUMENT


def refusable(form: str, claim_class: str) -> bool:
    """Whether this class accepts this form at all (a phone number never settles an artist claim)."""
    return form in SETTLES.get((claim_class or "").strip().lower(), (FORM_DOCUMENT,))


def normalise_email(value: Any) -> tuple[str, str]:
    """(the address lowercased, the reason it is not one; '' when it is)."""
    text = value.strip() if isinstance(value, str) else ""
    m = EMAIL.match(text)
    if not text or len(text) > 254 or not m:
        return "", "email_not_an_address"
    return text.lower(), ""


def normalise_phone(value: Any) -> tuple[str, str]:
    """(+E.164 digits, the reason it is not a number; '' when it is). Letters are never dropped:
    'call me on my mobile' is not a number."""
    text = value.strip() if isinstance(value, str) else ""
    if not text or not PHONE.match(text):
        return "", "phone_not_a_number"
    digits = re.sub(r"[^0-9]", "", text)
    if not MIN_PHONE_DIGITS <= len(digits) <= MAX_PHONE_DIGITS:
        return "", "phone_not_a_number"
    return "+" + digits, ""


def normalise_collaborator(value: Any) -> tuple[str, str]:
    """(the Muso profile id the collaborator was named by, the reason it is not one; '' when it is).
    A link (https://muso.ai/profile/<id>) or the bare id, and nothing else identifies a Muso user: a
    name, a handle or a sentence is not a reference, so it is refused at the intake rather than
    stored to be spent on a lookup that can only fail."""
    text = value.strip() if isinstance(value, str) else ""
    m = PROFILE_REF.search(text)
    if m:
        return page_identity.norm(m.group(1)), ""
    norm = page_identity.norm(text)
    return (norm, "") if PROFILE_ID.match(norm) else ("", "collaborator_ref_unreadable")


def _under(domain: str, hosts: frozenset[str]) -> bool:
    """Whether this domain IS one of `hosts` or sits under it (a subdomain of a free-mail or
    platform host is the same shared account)."""
    return domain in hosts or any(domain.endswith("." + h) for h in hosts)


def _hosts(value: Any) -> tuple[list[str], str]:
    if value is None:
        return [], "profile_hosts_unread"
    if not isinstance(value, (list, tuple)):
        return [], "profile_hosts_unread"
    return sorted({str(h).strip().lower().lstrip(".") for h in value if str(h).strip()}), ""


def check(form: str, value: Any, facts: Mapping[str, Any] | None) -> Supplied:
    """One supplied form, checked against the facts the reader delivered for this claim."""
    facts = dict(facts or {})
    if form in FORMS_WITHOUT_A_CHECK:
        # a measured NO: nothing can check it, so waiting on a fact would wait forever. The value is
        # still normalised, so the row's digest names WHAT was supplied even though it settles nothing.
        normalised, why = normalise(form, value)
        return Supplied(form, str(value or ""), normalised, False,
                        why or FORMS_WITHOUT_A_CHECK[form], {})
    if form == FORM_EMAIL:
        address, why = normalise_email(value)
        if why:
            return Supplied(form, str(value or ""), "", False, why, {"value": "unparsed"})
        domain = address.rsplit("@", 1)[1]
        if domain in FREE_MAIL or _under(domain, FREE_MAIL):
            return Supplied(form, str(value), address, False, "email_at_free_mail", {})
        if _under(domain, SHARED_HOSTS):
            return Supplied(form, str(value), address, False, "email_at_a_shared_host", {})
        # mailbox control: the supplied address must BE the address core records for this account,
        # and core must have CONFIRMED it (users.emailconfirmed). Anyone can type a local part at a
        # published domain, and an unconfirmed address is the claimant's word, so neither settles
        # anything: an unverified account is never offered this form at all (`checkable`).
        confirmed = facts.get("account_email_confirmed")
        account_digest = facts.get("account_email_sha256")
        if confirmed is None or not isinstance(account_digest, str):
            return Supplied(form, str(value), address, None, "account_email_unread", {})
        if confirmed is not True:
            return Supplied(form, str(value), address, False, "account_email_not_confirmed", {})
        if not account_digest.strip() or value_digest(form, address) != account_digest:
            return Supplied(form, str(value), address, False, "email_not_the_accounts_address", {})
        hosts, unread = _hosts(facts.get("profile_hosts"))
        if unread:
            return Supplied(form, str(value), address, None, unread, {})
        if not settles_at(domain, hosts):
            return Supplied(form, str(value), address, False, "email_domain_not_the_profiles",
                            {"profile_hosts": len(hosts)})
        return Supplied(form, str(value), address, True, "email_is_the_accounts_and_the_profiles_domain",
                        {"profile_hosts": len(hosts)})
    if form == FORM_PHONE:
        number, why = normalise_phone(value)
        if why:
            return Supplied(form, str(value or ""), "", False, why, {"value": "unparsed"})
        published = sorted({normalise_phone(p)[0] or str(p) for p in facts.get("profile_phones") or []})
        if number not in published:
            return Supplied(form, str(value), number, False, "phone_not_the_profiles", {"published": len(published)})
        return Supplied(form, str(value), number, True, "phone_published_by_the_profile", {"published": len(published)})
    if form == FORM_COLLABORATOR:
        ref, why = normalise_collaborator(value)
        if why:
            return Supplied(form, str(value or ""), "", False, why, {"value": "unparsed"})
        # the facts for THAT ref: a second supplied collaborator is never checked on the first one's
        given = (facts.get("collaborators") or {}).get(ref)
        found = given.get("in_catalog") if isinstance(given, Mapping) else None
        if found is None:
            return Supplied(form, str(value), ref, None, "collaborator_unresolved", {})
        if found is False:
            return Supplied(form, str(value), ref, False, "collaborator_not_a_muso_user", {})
        # an existing Muso user, not a public catalog row: the profile must be HELD by an account
        held = given.get("held_by_account")
        if held is None:
            return Supplied(form, str(value), ref, None, "collaborator_holder_unread", {})
        if held is False:
            return Supplied(form, str(value), ref, False, "collaborator_profile_not_held_by_an_account", {})
        if ref and page_identity.same_page(ref, page_identity.norm(facts.get("claimed_profile_id") or "")):
            return Supplied(form, str(value), ref, False, "collaborator_is_the_claimant", {})
        mine, theirs = facts.get("profile_titles"), given.get("titles")
        if mine is None or theirs is None:
            return Supplied(form, str(value), ref, None, "collaborator_tracks_unread", {})
        shared = sorted(set(mine) & set(theirs))
        if not shared:
            return Supplied(form, str(value), ref, False, "collaborator_not_on_a_release",
                            {"profile_titles": len(set(mine))})
        return Supplied(form, str(value), ref, True, "collaborator_credited_on_the_same_release",
                        {"shared_titles": len(shared)})
    if form == FORM_DOCUMENT:
        raise ValueError("a document is read by the ladder's own gates, not by forms.check")
    raise ValueError(f"unknown form {form!r}")


CHECKS = {f: check for f in (FORM_EMAIL, FORM_PHONE, FORM_COLLABORATOR)}

# The one normaliser per form: what a supplied value IS once its shape is known, or the reason it is
# not that shape. A value that is not the shape is refused where it is taken in, never stored to be
# judged later.
NORMALISERS: dict[str, Callable[[Any], tuple[str, str]]] = {
    FORM_EMAIL: normalise_email, FORM_PHONE: normalise_phone, FORM_COLLABORATOR: normalise_collaborator}


def normalise(form: str, value: Any) -> tuple[str, str]:
    """(the value in the form's own shape, why it is not that shape)."""
    fn = NORMALISERS.get(form)
    if fn is None:
        raise ValueError(f"{form!r} is not a supplied form; a document is read by the ladder's own gates")
    return fn(value)


def host_of(url: Any) -> str:
    """The registrable host a profile publishes, '' when the link is not one we can read."""
    return bound_pages.registrable_host(url) or ""
