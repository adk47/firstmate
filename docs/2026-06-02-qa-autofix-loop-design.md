# QA review trust + BugBot-style autofix loop — design

**Date:** 2026-06-02
**Author:** Nick (with Claude)
**Status:** Design — pending review
**Related:** PR #391 (QA auto-review shipped), #392 (branch protection), #396 (DM threading), **#397 (CTO→Codex coding — hard dependency for Part B)**, incident PR #287 (the mis-approval that motivated this)

---

## 1. Problem

On 2026-06-01 the "Muso QA Bot" posted **"Approved — CI green, no blocking findings. Safe to merge"** on PR #287, while four findings it had raised minutes earlier were still unaddressed. Ground truth from the PR's review timeline:

| Time (UTC) | Verdict | Head commit |
|---|---|---|
| 20:16:58 | 🟡 HOLD — 2 Important | `0ca39cc` |
| 20:22:14 | 🔴 NOT-GO — 1 Critical + 1 Important | `8539d54` |
| 20:31:24 | ✅ GO — 0 Critical, 0 Important | `acd77f7` |
| 20:31:30 | **APPROVED** | `acd77f7` |

`git diff --name-only 8539d54 acd77f7` = **only `openclaw-main.json`** (a model-fallback tweak). None of the four flagged files were touched, and all four findings are still present verbatim at the branch tip:

- 🔴 `fetch-conversations.sh:84` — customer surname leak (no `.source.author.name` fallback → `redact.sh` won't scrub it).
- 🟡 `SKILL.md:34` — `redact.sh` invoked with no args (script exits → workflow halts).
- 🟡 `grading-rubric.md` — em-dashes violate the skill's own voice rule (10 still present).
- 🟡 `tests/fetch-audit.bats` — still does not exist.

### 1.1 Root causes

1. **Stateless / amnesiac review.** `skills-all/muso-github-code-review/SKILL.md` derives GO/NO-GO from a *fresh* 7-lens pass each run (SKILL.md:155-180, 333-356). It never re-reads its own prior comments or human/Clio review threads, and never checks whether previously-flagged Critical/Important findings were addressed. A run that fails to re-surface a bug yields "0 Critical, 0 Important" → GO. "no blocking findings" (SKILL.md:72) comes *only* from that single pass — not from CI, not from open comments.

2. **No mechanical enforcement of the verdict.** `scripts/qa-pr-approve.sh` enforces only identity/format guards (owner, requester allowlist, no self-approval, log-before-write — qa-pr-approve.sh:62-87). It never inspects CI status *or* finding severity. The GO decision is purely the LLM's word; the only CI/reviewDecision read is a *post-approval* report (qa-pr-approve.sh:94-97) that cannot block.

3. **QA findings can't turn CI red.** Per `docs/GOVERNANCE.md:193`, `main` has **no required status checks**; merge is gated solely by 1 code-owner approval (`* @adk47`), which the QA bot's own `@adk47` approval satisfies. So a QA NO-GO produces only a withheld approval + a COMMENT review — never a red check.

This generalizes a pattern already in our memory (`feedback_llm_instruction_insufficient`): **skill prose is not enforcement.** The verdict must be re-derived in a mechanical layer.

## 2. Goals / non-goals

**Goals**
- QA must never post "safe to merge" while unaddressed Critical/Important findings exist (its own or anyone's).
- A QA NO-GO produces a **visible red signal** on the PR and blocks merge.
- Approval is gated by a mechanical re-derivation of CI-green + no-open-blockers, not by the agent's self-report.
- (Part B) A Cursor/BugBot-style loop where the CTO agent (Codex) auto-fixes confirmed findings, QA re-reviews each push, and the cycle repeats until green — with progress posted in the Slack thread.

**Non-goals**
- QA merging PRs (stays approve-only, never merges).
- Auto-fixing findings on non-Nick PRs in the first iteration (keep blast radius small; nsollazzo-only as today).
- Replacing human review judgement — humans retain break-glass and final merge.

## 3. Design

### Part A — Make QA's verdict trustworthy (PR #1, no dependency, ships first)

**A1. Carry findings forward.** Before computing GO, the skill enumerates **all unresolved review threads** on the PR — its own prior inline comments and human/Clio's — via `gh api repos/<owner>/<repo>/pulls/<n>/comments` plus the GraphQL `reviewThreads { isResolved }` field. Severity classification:
- QA's own prior comments carry the 🔴/🟡/🟢/🔵 tag → read it directly.
- Human/external unresolved threads lack our tag → QA classifies them with its own 7-lens judgement during the fresh pass; an unresolved human thread QA judges Critical/Important counts as a blocker. (Note: on #287 there were *no* human threads on the PR — Clio's feedback landed off-PR via commits — so the dominant carry-forward path is QA's own tagged findings.)

**Any unresolved 🔴 Critical or 🟡 Important thread is a standing blocker** that the fresh 7-lens pass cannot erase. The verdict = (fresh-pass findings) ∪ (unresolved prior blockers).

**A2. Red `qa-review` commit status.** The skill posts a commit status against the head SHA:
- `POST /repos/<owner>/<repo>/statuses/<sha>` with `context=qa-review`, `state=success` on GO, `state=failure` on NO-GO, `state=pending` while reviewing, `target_url` → the review.
- Commit statuses chosen over Check Runs: any repo-scoped token can set them (no GitHub App / `checks:write`), and they are requireable in branch protection.
- A new push = new SHA = no `qa-review` status yet → not mergeable until re-reviewed. Pairs with `dismiss_stale_reviews` (enabled in #392).

**A3. Move the gate into the wrapper (load-bearing).** Harden `scripts/qa-pr-approve.sh` so it **independently re-derives** the gate before running `gh pr review --approve`, refusing (non-zero exit) if any of:
- CI is not fully green — reads `statusCheckRollup` (excluding the `qa-review` context itself, to avoid a circular dependency) and refuses on any non-passing check **or an empty rollup** (exit 8, fail-closed — an empty rollup is not proof CI ran).
- Any unresolved 🔴 Critical or 🟡 Important review thread exists (exit 9), **failing closed when there are >100 threads** to page through.

The wrapper deliberately does **not** gate on the `qa-review` status itself: that status is QA-set, so checking it would be circular — Guard 6 excludes it, and A2's status stays a best-effort *visible* signal, not part of the mechanical gate. This is the real fix: even if the LLM hallucinates "GO", the bash gate blocks the approval. New exit code + a bats case per failure mode. The skill still computes/encodes the verdict, but the wrapper no longer trusts it blindly.

**A4. Honest DM template.** SKILL.md:72's "no blocking findings" derives from the A1 unresolved-thread check; the success line fires only after A3's wrapper succeeds. NO-GO DM enumerates the open blockers + their file:line.

**NOT a required status check (intentional).** A naive "make `qa-review` required" would block every non-`nsollazzo` PR, because required checks are repo-wide but QA only runs on Nick's PRs and `CODEOWNERS` is `* @adk47` — so other contributors' PRs would hang on a never-reported check. The real merge block is the **wrapper refusing the required code-owner approval** (A3) when CI isn't green or a blocker is open; the red `qa-review` status is the visible ❌ + defense-in-depth. Revisit making it required only if QA is widened to review all PRs (scope expansion, deferred).

**Part A files:** `skills-all/muso-github-code-review/SKILL.md` (A1, A2, A4), `scripts/qa-pr-approve.sh` + `scripts/tests/qa-pr-approve.bats` (A3), `scripts/qa-dispatch-pr-review.sh` (dispatch message reflects carry-forward), `docs/GOVERNANCE.md` (document the gate; `qa-review` is deliberately not made required).

### Part B — Autofix loop (PR #2, depends on #397 merging)

```
QA reviews → NO-GO (red qa-review status) → hands CTO the confirmed 🔴/🟡 findings
   → CTO (Codex) triages each: real bug? fix it : reply on thread with rationale
   → CTO commits fixes to the PR branch (in place), pushes
   → push re-triggers PR Validation → re-triggers qa-autoreview
   → QA carries findings forward (A1), marks resolved, updates qa-review status (A2)
   → loop until GO  (or attempt cap = 3, or no-progress)
   → on GO: QA approves via hardened wrapper (A3).  on cap: ping human (break-glass)
```

**B1. Fix actor = CTO via extended `codex-delegate.sh`.** #397 gives CTO the ability to implement a hydra change and open a *new* branch+PR (`prepare`/`finalize`/`abort`), with hard gates (hydra-only, requester allowlist, never merges, never shells out to `codex`). The loop needs a **new mode that operates on the existing PR branch in place** — check out the PR head branch, let CTO edit, commit referencing the finding fingerprint, push — *without* opening a new PR. This is the principal new plumbing for Part B.

**B2. QA→CTO handoff.** On NO-GO, QA hands CTO the confirmed blockers (file:line + body + a stable fingerprint). Mechanism options to decide in planning: agent-to-agent message (`agentToAgent.enabled=true`) vs. QA enqueuing a CTO autofix one-shot cron (mirroring `qa-dispatch-pr-review.sh`). Lean toward the cron-dispatch pattern for symmetry and durability.

**B3. False-positive guard.** CTO confirms each finding is a real bug before editing. If it judges a false positive, it **replies on the thread with reasoning** instead of changing code (Rule 5 — surgical changes; avoid "fixing" non-bugs). A CTO false-positive rationale is a signal QA weighs on re-review (may resolve the thread).

**B4. Loop safety.** Hard attempt cap = **3** (Cursor's BugBot number) per PR, tracked durably (e.g. a counter in the sticky comment or the audit log keyed by PR). No-progress detection: if a re-review shows the same finding persisting after a CTO attempt, stop and escalate. Bounds runaway Codex spend.

**B5. Progress in-thread.** Reuse the single-DM threading from #396: "fixed 2/3 in `<sha>`, re-reviewing…", "attempt 3/3 reached, 1 finding remains — needs you."

**Part B files (anticipated):** `scripts/codex-delegate.sh` (+ tests) for the in-place mode; new dispatch/loop plumbing; `skills-all/muso-github-code-review/SKILL.md` (NO-GO → handoff); `workspaces/cto/SOUL.md` (autofix-loop scope); possibly a new `skills-all/` skill for the CTO fix step.

## 4. Separation-of-duties wrinkle (Part B)

Clean at the *agent* level: CTO writes, QA approves; the wrapper already refuses self-approval (PR author == approver). But CTO's pushes and QA's approval may share the **same `adk47` GitHub identity** on node-8, so at the git-identity layer "the entity that wrote the code also approved it." The mechanical A3 gate (no unresolved blockers + CI green) is the real protection regardless of identity. **Open item for Part B planning** — do not hand-wave; decide whether distinct GitHub identities are warranted.

## 5. Dependencies & things to verify on node-8

- **PR #397 must merge before Part B** (the fix-actor substrate).
- No required-check / branch-protection change in Part A (see §3 — `qa-review` is deliberately not made required; the wrapper refusal is the merge block). An optional future Aaron action only if QA is widened to all PRs.
- Verify on node-8 (per `feedback_test_on_node8_not_local`): GraphQL `reviewThreads.isResolved` available to the host `gh` token; the host token can `POST .../statuses/`; the QA cron resolves to the expected Codex account; whether `policies/tool-deny-lists.yaml` is enforced at runtime (research found it may be doc-only — relevant if CTO's pushes must be gated by more than the wrapper).
- `codex-delegate.sh` in-place-branch mode must respect the same gates as #397 (hydra-only, requester allowlist, never merge, never invoke `codex`, audit log).

## 6. Testing

- **Part A:** bats cases for `qa-pr-approve.sh` covering each new refusal (CI not green, incl. an empty rollup; unresolved Critical; unresolved Important; `>100` threads / `hasNextPage`). Tests must PATH-shadow `openclaw`/`gh` so they never hit real Slack/GitHub (`feedback_bats_must_stub_openclaw`). A replay fixture of the #287 thread state asserting the wrapper now refuses.
- **Part B:** bats for the in-place mode (checks out existing branch, never opens a new PR, never invokes `codex`, honors the attempt cap, honors the allowlist). Live Slack smoke after deploy (the skill-load + agent integration is only exercisable on the gateway), driven from Nick's DM.

## 7. Rollout

1. Part A PR → CI → CD deploy → confirm a NO-GO PR shows a red `qa-review` status and the wrapper refuses to approve (the merge block is the withheld code-owner approval). **Do NOT add a required `qa-review` status check** — it would block every non-`nsollazzo` PR on a status that never reports for them (see §3/§5); revisit only if QA is widened to all PRs.
2. Land #397 (its own post-merge live smoke).
3. Part B PR (in-place mode + loop) → deploy → live smoke on a deliberately-buggy throwaway PR → confirm fix→re-review→green→approve and the attempt-cap escalation path.

## 8. Open questions

- B2 handoff mechanism: agent-to-agent vs. cron dispatch (lean cron).
- B4 attempt-counter storage: sticky comment vs. audit-log keyed by PR.
- Section 4: one shared `adk47` identity vs. distinct CTO/QA GitHub identities.
- Scope widening beyond nsollazzo PRs — deferred.
