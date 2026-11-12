# Lines this PR deletes that landed on main in the last 14 days

The QA rebase warning on https://github.com/Muso-AI/hydra/pull/1908 named four files: `identity.py` (10 lines),
`run.py` (9), `store.py` (6), `tests/test_gdpr_pipeline.py` (15). This is every such line, read from the diff and
`git blame` on the merge base, not inferred from a clean rebase. Method: for each hunk of `merge-base..head`, each
deleted line whose blame commit on the base is under 14 days old, with the lines the same hunk adds.
My count is a superset of the analyzer's for two files (`run.py` 14, tests 16 at `3840a4f43`): it also counts a
changed import line, a docstring line and comment-only lines the analyzer's normaliser drops. All are listed. Run
again on the head pushed after that review (base `8b9e7568a`), it finds three more: one test line and two lines of
`install-aux-units.sh`. They are listed too. Run once more on the head that answers the review of `7fb67dbd5`
(base `fa1c3072c`), it finds three more in `run.py`, all from `c3d1ce1fc` (#1779): `ask_refusal` gained a third
argument. Listed.

**Result: 52 lines in 33 hunks, in five files. Every one is an intended replacement. No hunk from another lane's
work is lost.**
Two kinds:

- **Replaced by the captain's 2026-11-12 ruling** (a name match is not a tie to a page; a statutory date pages
  nobody by name). These remove behaviour on purpose: paths B and C no longer pass, and the due-date page no longer
  mentions Jan.
- **Extended in place.** The deleted line is still there with more on it (a tuple with new members, a condition
  with one more arm). Nothing it did is gone.

The five commits from other lanes whose lines are touched, and what happened to each:

| main commit | what it added | what this PR did to it |
|---|---|---|
| `9f25b0b23` #1848, operator path for an unfinished send | `elif slot == "confirm":` in `Store.stamp_sent` | kept; one arm added (`or kind == "access"`), same body |
| `1925c21ba` #1735, one event on two channels is one request | the stamp-pair tuple and the "earlier stamp wins" merge | kept; two pairs added, and the original condition is now the `elif` under a new "latest wins" case for `status_sent_at` only |
| `d9e67e21b`, track/album hides through the identity gate | a test asserting an item passes on its artist's name match | the assertion now expects `JAN_REVIEW`, and the same test gained the own-site pass (`PASS_D`) |
| `ffece3690` #1749, a new thread from support@ for a notices@/legal@ request | a test fixture row with `identity_verdict="ASK_IDENTITY"` | the fixture uses `ASK_LINK`; the new-thread behaviour under test is unchanged and still asserted |
| `e10f4a38f` #1816, the tick unit's seat is expanded by systemd | the tick's `ExecStart` line | kept whole, `\$GDPR_SENDER_SEAT` included; `--ladder --ladder-limit 25` appended |

## scripts/gdpr_pipeline/identity.py: 10 lines, 2 hunks (all from `fc95ad267`, 11-04)

| deleted | replaced by | why |
|---|---|---|
| `return v(PASS_B, "B: the contact resolves to account N, whose name matches the page")` | `return v(ASK_IDENTITY, "... a name match is not a tie to the page: ask them to claim it or send evidence of authority")` | ruling: an account whose NAME equals the page name has not shown the page is theirs |
| 9 lines of path C: `if big_name(p): return v(JAN_BIGNAME, ... "goes to Jan")`; the comment and `if not r.verified: return v(ASK_IDENTITY, "... the sender is not verified ...")`; `return v(PASS_C, "C: unclaimed page whose display name equals the requester's name")` | `return v(ASK_IDENTITY, "the requester's name or address matches the page name, but a name match is not a tie to the page ...")` | ruling: path C never passes, so its two guards have nothing left to guard. The unverified-sender case still ends in `ASK_IDENTITY`; the big-name case no longer goes to a named person's queue |

`PASS_B`, `PASS_C` and `JAN_BIGNAME` stay defined, because rows decided before the ruling carry them. A test asserts
no code path returns `PASS_B` or `PASS_C` now.

## scripts/gdpr_pipeline/run.py: 17 lines, 9 hunks

| deleted | replaced by | why |
|---|---|---|
| `from gdpr_pipeline import copy, identity, intake, sources` | the same import with `access, copy_gate, dsar` added | extended |
| 9 lines in `Run.decide`: `name = ...`, `email = ...`, the six-line provenance comment, `trusted = (...)`, `rep = intake.is_representative(...)` | `name, email, trusted, rep = requester_of(r, conv)` | **moved, byte for byte, into `requester_of()`** (same file), comment included as its docstring. One function so the identity decision and the Art. 15 copy cannot disagree about who the requester is |
| the closing line of `Run.asks`'s docstring (from `c3d1ce1fc`, 11-06) | the same sentence, then the paragraph on when the older ask stands down | extended |
| `"""(register_no, line) to page: due_at - 3 d reached without confirmed_at; ...` | the same line with "(7 d for an erasure or access request)" | extended |
| `if not r["confirmed_at"] and now >= due - timedelta(days=WARN_DAYS):` | `warn = dsar.ALARM_DAYS if r["class"] in dsar.STATUTORY else WARN_DAYS`, then the same condition on `warn` | widened for statutory classes only; every other class keeps 3 days |
| ``base = head or (f"<@{JAN}> :hourglass: *GDPR erasure register: ...`` | the same line without `<@{JAN}>` | ruling: the due-date page names no person |
| `def ask_refusal(cls: str, past_due: bool) -> str:` (`c3d1ce1fc`, #1779) | `def ask_refusal(cls: str, past_due: bool, kind: str = "") -> str:` | extended: the two-argument call still works and returns what it did (a test holds that) |
| `Two independent reasons, and the class one is checked FIRST ...` (its docstring) | `Three independent reasons, ...` | extended: the class reason and the past-due reason are unchanged and still checked first |
| `"refuse": ask_refusal(r["class"], past_due)})` in `Run.asks` | `"refuse": ask_refusal(r["class"], past_due, kind)})` | extended: the third reason refuses the identity step's words for a statutory request |

## scripts/gdpr_pipeline/store.py: 6 lines, 6 hunks

| deleted | replaced by | why |
|---|---|---|
| `JSON_COLS = (..., "hidden_pages")` | the same tuple with `"gates"`, plus `JSON_OBJECT_COLS = ("hide_pr", "gates")` | extended |
| the last line of the column-migration tuple, `("interim_confirm_at", ...), ("interim_confirm_ref", ...))` | the same two columns, then the ladder's columns | extended |
| `d[c] = json.loads(d.get(c) or ("{}" if c == "hide_pr" else "[]"))` | `... if c in JSON_OBJECT_COLS else "[]"` | same result for `hide_pr`; `gates` also decodes to `{}` |
| `elif slot == "confirm":` (`9f25b0b23`, #1848) | `elif slot == "confirm" or kind == "access":` with the same body, after new arms for `ack` and `status` | extended. Without the `status` arm a status update fell through to the interim-confirmation stamp |
| `("interim_confirm_at", "interim_confirm_ref"))` (`1925c21ba`, #1735) | the same pair, then `("ack_sent_at", "ack_ref"), ("status_sent_at", "status_ref"))` | extended |
| `if not b or (a and a <= b):` (`1925c21ba`, #1735) | `if at in LATEST_STAMPS: ... elif not b or (a and a <= b):` | the original rule is the `elif`, unchanged, for every stamp it applied to before |

## tests/test_gdpr_pipeline.py: 17 lines, 14 hunks

Every one is an assertion or a test name for the behaviour the ruling replaced. Each test is still there, asserting
the new behaviour.

| deleted | replaced by |
|---|---|
| `def test_arpad_is_path_c` | `def test_a_name_match_alone_is_not_a_tie_to_the_page` |
| `assertEqual((d.verdict, d.basis), ("PASS_C", "C"))` and the comment "the SAME name/email from an unverified ticket is an ASK" | `assertEqual(..., ("ASK_IDENTITY", ""))`, `assertIn("not a tie", ...)` |
| `assertIn("not verified", d2.pages[0].why)` | nothing: the unverified case is still asserted to be `ASK_IDENTITY` on the line above; its reason is now the same "not a tie" as the verified case |
| `def test_email_local_part_alone_counts_for_c` and its `"PASS_C"` | `def test_email_local_part_alone_is_not_a_tie_either`, `"ASK_IDENTITY"` |
| `def test_big_name_goes_to_jan_not_c` and two `"JAN_BIGNAME"` assertions | `def test_a_name_match_on_a_big_name_page_is_an_ask_not_a_persons_queue`, two `"ASK_IDENTITY"` assertions, and a new test that no path returns `PASS_B` or `PASS_C` |
| `def test_path_b_needs_the_accounts_name_to_match` and its `"PASS_B"` (3 lines) | `def test_an_account_whose_name_matches_is_asked_to_claim_the_page`, `"ASK_IDENTITY"`, `assertIn("not a tie", ...)` |
| `assertEqual((d.verdict, d.basis), ("PASS_C", "C"))` in the item test (`d9e67e21b`, 11-11) | `("JAN_REVIEW", "")`, plus the own-site case asserting `("PASS_D", "D")` |
| `["PASS_C", "UNKNOWN"]` | `["ASK_IDENTITY", "UNKNOWN"]` |
| `{ARPAD: "PASS_C", OTHER: "ASK_IDENTITY"}` | `{ARPAD: "ASK_IDENTITY", OTHER: "ASK_IDENTITY"}`, plus a claimed-page case asserting `{ARPAD: "PASS_A", ...}` |
| `assertIn("<@U038BM16T7W>", page_text(lines))` | `assertNotIn("<@", page_text(lines))` and an assertion on the page's heading |
| `self.s.update(rid, "decide", identity_verdict="ASK_IDENTITY", due_at=...)` in the new-thread test (`ffece3690`, 11-06) | the same line with `"ASK_LINK"` and a comment: the identity step is never sent for a statutory request, so the fixture needs an ask that still goes |

## scripts/install-aux-units.sh: 2 lines, 2 hunks

| deleted | replaced by | why |
|---|---|---|
| the comment line `... the watchdog: pages #cs_priority (Jan) at most once a` | the same comment saying no person is named and the clock check carries the date to firstmate | ruling: the due-date page names no person |
| the tick's `ExecStart=... tick --page --send --limit 25 --approved-by \$GDPR_SENDER_SEAT` (`e10f4a38f`, #1816) | the same line with `--ladder --ladder-limit 25` appended | extended; the systemd-expanded seat from #1816 is untouched, and `install-aux-units-gdpr-tick.bats` still holds it |

## The other direction: what main added while this branch was open

The list above is lines this PR deletes. A rebase can also lose a line main ADDED after the branch point. Checked
at the rebase onto `8b9e7568a` (2026-11-12T14:08Z), not assumed: between the old merge base `54e6d13eb` and
`8b9e7568a`, main changed three files this PR also changes: `.github/workflows/pr-validate.yml` (+13),
`AGENTS.md` (+10, -1) and `scripts/install-aux-units.sh` (+47). All 70 added lines are present in the rebased
tree, and the one line main deleted from `AGENTS.md` is absent from it.

At the rebase onto `fa1c3072c` (2026-11-12T17:00Z): main's one new commit (#1917) changes four files under
`scripts/credit_review/` and `scripts/tests/`, none of which this PR touches, so there was nothing to lose.
