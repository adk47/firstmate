"""Shared shadow-evaluation harness for every Muso verifier (credits / claims / merges).

Labelled ground-truth sets (``sets/*.jsonl.gz``) + a runner that replays any verifier in
shadow and reports precision, recall and false-approve counts per class, paid first.
Nothing in this package writes to Muso, Intercom, Slack or any admin API: it reads frozen
sets, calls a pure verifier function (or reads a recorded shadow-verdict log), and writes
report files under its own output directory. See docs/credit-verification/verifier-eval.md.
"""
