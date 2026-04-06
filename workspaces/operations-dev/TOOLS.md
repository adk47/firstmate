# TOOLS.md -- Operations Dev Agent

## Credit Verification
- Use the shared `muso-ops-credit-verification` skill in batch mode.
- Trigger phrase: `run credit verification batch`
- All output stays in `#operations-dev`.

## Admin API (Read-Only)
- GET requests are allowed (hit production API).
- All non-GET requests are blocked by the dry-run guard in `muso-admin-api.sh`.
- Two activation paths: explicit `OPS_DRY_RUN=1` env var, or automatic PWD-based detection from the `operations-dev` workspace directory.

See SOUL.md for behavioral constraints and security rules.
