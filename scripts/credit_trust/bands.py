"""The credit-trust band table, mirrored byte for byte from industry-data-processing.

Source of truth: ``common/credit_trust_bands.json`` in Muso-AI/industry-data-processing (the
credit validator writes ``verificationData.band_hint``, ``proof_required``, ``hold_reason`` from
it). This repo keeps an exact copy next to this module so the Ops decision runner (T07), the
digest (T09) and Caroline's case tools read the SAME bands, rules and plain hold sentences.

Change both repos in the same pair of PRs: copy the IDP file verbatim, then update
``IDP_SOURCE_SHA256`` / ``IDP_SOURCE_COMMIT`` below. ``scripts/tests/test_credit_trust_bands.py``
fails when the copy and the pin disagree, and compares against an IDP checkout when
``IDP_CHECKOUT`` is set (IDP's own parity test does the reverse with ``HYDRA_CHECKOUT``).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

BANDS_PATH = Path(__file__).with_name("credit_trust_bands.json")
#: Path of the source file inside an industry-data-processing checkout.
IDP_SOURCE_PATH = "common/credit_trust_bands.json"
#: sha256 of the IDP file this copy was taken from, and the IDP main commit that carried it.
IDP_SOURCE_SHA256 = "3d471abc42d14a418ed1c8945efab1071f59d01649925dd8d0ec7f82eac089b6"
IDP_SOURCE_COMMIT = "51347ebb"  # industry-data-processing #1738

BANDS_BYTES = BANDS_PATH.read_bytes()
BANDS = json.loads(BANDS_BYTES)
BANDS_SHA256 = hashlib.sha256(BANDS_BYTES).hexdigest()


def hold_rule_names() -> frozenset[str]:
    """Every banded review_/reject_ rule (B or C)."""
    return frozenset(BANDS["band_b_rules"]) | frozenset(BANDS["band_c_rules"])


def hold_reason_sentence(code: str) -> str | None:
    """The plain sentence IDP stores for a hold code, or None when the code has none."""
    return BANDS["hold_reasons"]["rules"].get(code)
