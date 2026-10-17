"""Credit trust system (Fable design, 2026-10-15): the hydra side.

T01 ships the model layer every credit-trust AI step shares:
  * llm.py    - the provider ladder (Codex on the subscription -> Jev),
                tool-less, with prompt hashes;
  * ledger.py - the append-only ``llm_calls`` audit table every call writes.

T07/T11 share the band table:
  * bands.py  - the byte-for-byte mirror of IDP's credit_trust_bands.json.

Design: docs/credit-verification/credit-trust-llm.md
"""
