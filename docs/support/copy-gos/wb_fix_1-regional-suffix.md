# GO evidence: wb_fix_1 regional suffix

One file per granted GO. `policies/winback-fix.json` may name a `fable_go_ref` only when a file
here carries that same ref, the approved copy verbatim, and the ruling that granted it;
`tests/test_churn_copy_gos.py` fails the build otherwise, so a ref cannot be self-granted.

## Approval ref

`fable-ruling-1104-d2/wbfix1-regional-suffix`

## Approved text

```
 Your regional discount still applies, so the price stays the same.
```

## Ruling (verbatim)

```
Fable driver (for firstmate, single sender seat), 14:2xZ - wb_fix_1 regional sentence: GO on the exact text ' Your regional discount still applies, so the price stays the same.' (leading space, appended after the approved offer line), under these conditions which are already your code: only the 61 Regional-Discount cancellations who still HOLD the country coupon at send time (re-check per user at send, not at list build - if the coupon lapsed between build and send, the sentence is dropped for that user, never sent false); no new discount, no amount stated, one message per user after R2 (fix confirmed). Approval ref to record in policies/winback-fix.json offers.regional_suffix.fable_go_ref: fable-ruling-1104-d2/wbfix1-regional-suffix. Post the first day's count (sent with suffix / held-coupon-lapsed) to me.
```

## Date

2026-11-04T14:18:11Z

## Approver seat

`verify-sla-driver-fable-d2`, the single sender seat (the Fable driver, granting for firstmate).

## Conditions

1. Only the Regional-Discount cancellations who still HOLD the country coupon at send time. The
   coupon is re-checked per user at send (`scripts/churn/coupons.py`), never at list build; if it
   lapsed between build and send the sentence is dropped for that user and never sent false.
2. No new discount is created and no amount is stated in the sentence.
3. One message per user, and only after R2 (the fix is confirmed first).

## Archive

Firstmate instruction inbox message 004 for `support-churn-winback-fix-first-w1`, schema
`fm-task-inbox.v1`, `at=2026-11-04T14:18:11Z`, sender seat `verify-sla-driver-fable-d2`. That
archive lives outside this repository (firstmate state), so this file is the in-repo record of
the ruling.
