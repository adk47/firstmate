"""GDPR erasure pipeline: the register as a machine record (Fable `gdpr-ruling-for-jan.md` §3).

intake -> identity (gdpr-ack-v2 §3, paths A-E + legal_threat) -> reversible hide batch PR
-> written confirmation on/before due_at -> watchdog. Never deletes anything.
See docs/support/gdpr-pipeline.md.
"""
