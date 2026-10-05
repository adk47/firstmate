---
name: muso-ad-screening
description: |
  The one sanctioned WRITE path for the ad-screening verdict: PUT /admin/ads/<adId>/screening
  through scripts/muso-ad-screening.sh. Reject-by-default: numeric adId only, allowlisted
  payload keys only, hard-coded method and route. Used by the ad screener; not a general
  Muso write tool (muso-read stays GET-only).
compatibility: |
  Main gateway on node-8 only. Calls the deployed `muso` binary with the gateway's
  MUSO_ADMIN_* env. Kill switch: /etc/hydra/ad-screening.disabled (exit 6).
---

# muso-ad-screening

```
bash scripts/muso-ad-screening.sh put <adId> <payload.json>
```

Exit codes: `0` ok / `2` usage / `3` refused / `6` disabled. See the script header for the
payload key allowlist and env overrides.
