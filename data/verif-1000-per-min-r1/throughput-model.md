# Throughput model: 1,000 verification actions per minute

Written 2026-11-14 01:30Z. Every number below names where it was read. "Unmeasured" means nobody has
measured it, and it is not treated as fine.

## The target in messages

| Shape | Messages |
|---|---|
| 1,000/min held for 10 minutes | 10,000 |
| Ramp 100 → 200 → 400 → 800 → 1,000 per minute, 10 clean minutes at each step | 25,000 in 50 minutes |
| Whole never-asked population, one action per request | 71,204 (71 minutes at 1,000/min) |

The supply is finite. The brief counts 86,302 requests that need an ask (71,204 never asked). One message
per user per UTC day, a 7-day cooldown and a 90-day re-ask lock mean that after one pass over those people
there is nothing left to send at that rate: 1,000/min is a drain that lasts about an hour, once, and then
a small daily tail. The number of distinct users behind the 71,204 requests is unmeasured in this lane; it
is the real message count and it is lower than the request count.

## Hard limits per channel

| Channel | Limit | Source | Carries 1,000/min? |
|---|---|---|---|
| Email, send-gateway `notify` route, batch keys (`credit-status:`) | **3,000 per UTC day** (`WARMUP_CEILINGS`), 0 used today | live ConfigMap `send-gateway-config` and `GET /v1/warmup`, read in-pod 01:07:28Z | Not today. 1,000/min spends the day's ceiling in 3 minutes. |
| Email, gateway auto-pause | hard bounce > 1.0 % or complaint > 0.1 %, over the last 24 h, once 50 are sent; health cached 5 min | same read (`pause` block) and `services/send-gateway/src/warmup.js` | Stricter than the 2 % in the contract. It is a 24 h window, not a 10 minute one. |
| Email, current route health | 24 h: 2,359 sent, 1 hard bounce (0.04 %), 117 soft (4.96 %), 0 complaints | same read | Healthy on hard bounces. Soft bounces are already 5 % at 2,400 a day. |
| Email, provider (Mailgun) | 80,000 calls per 10 s on `/messages` | `data/verif-bulk-throughput-v1/design.md` (documented limit, not re-read here) | The API is not the limit. What our account and domain are accepted at is unmeasured: no burst has ever been run. |
| Email, gateway capacity | 2 pods, 100m CPU request, 512Mi; per send = claim the key in Postgres, one Mailgun call, record the row | `kubectl get deploy` 01:0xZ, `server.js:457-490` | Unmeasured. No per-send latency on file. |
| Email, our queue | 6,327 sends/min, 8 workers, every outcome fsynced | `docs/credit-verification/bulk-send-queue.md` (fake provider, 2 ms latency, ak47) | Yes, with room. Not the limit. |
| Intercom, API | 10,000 calls/min per workspace, shared with Caroline's live traffic | `data/verif-bulk-throughput-v1/design.md` | No. See below. |
| Intercom, the gate as built | 17 sends in 155 s at a pool of 8 = 6.6/min; about 20/min at 6 workers on another run | ledger rows 13750-13766 (run 20261113T2326Z); rows 13548-13566 | No. 150 times short, and the send is not idempotent: Intercom keeps no key of ours. |
| Core writes (approve, close) | 120 calls/min per agent identity; one request id per PUT, plus the anchor GET | verif-decision-predicates-d3 status; `scale_drain.py` gate | No. At most 120 decisions/min per identity, and only 674 requests are approvable. |
| Replica reads | about 2 s fixed cost per `trino-query.sh` call | AGENTS.md "A replica question costs ~2 s" | Only as one bulk read for the whole audience. Per person it needs 33 parallel streams. |
| Decide / select | 17.2M decisions/min | `bulk_queue.py decide`, 100k people | Not a limit. |

## Which channel can carry it

**Email through send-gateway is the only one.** Intercom cannot (one conversation per user, a
non-idempotent send, 6.6 to 20 a minute measured). Decisions cannot (674 approvable, 120 writes a minute).

Email cannot carry it **today**, for two reasons that are not code in this repo:

1. **The warm-up ceiling is 3,000 batch emails per UTC day on `notify`.** It lives in H-DevOps
   `k8s/prod/messaging/78-send-gateway.yaml`. The ramp in the brief needs 25,000 in 50 minutes; the full
   drain needs about 71,000 in a day. The domain has been sending about 2,400 a day. Raising the ceiling
   is a PR in another repo, and it is a deliverability decision: ten to thirty times a domain's daily
   volume inside one hour is what mailbox providers throttle, and the route already soft-bounces 5 %.
   That risk is not measured; nobody has sent a burst from this domain.
2. **The email ask is switched off by a recorded captain decision.** `scripts/paid-status/daily.sh:92`
   strips the ask copy from every email plan ("firstmate 024", captain 2026-10-27: no proof ask offering
   documents until a returned document can be accepted). The reason still holds in part: 11,084 documents
   are on file with no verdict, and no job turns a read document into a decision
   (`docs/credit-verification/proof-path.md`). At the 2.3 % response rate on file, 71,204 asks bring in
   about 1,600 more documents.

## What "a clean 10-minute window" can and cannot show

- Hard bounces come back from Mailgun within minutes, so a 10-minute window sees most of them, read
  through `GET /v1/warmup` (ClickHouse `email_events`, cached 5 minutes: a window is at most two reads).
- Complaints arrive hours to days later. A 10-minute window says nothing about them.
- Deferrals (4xx) from a provider that is throttling us show as soft bounces and as mail still queued at
  Mailgun, not as hard bounces. The sender has to hold on soft-bounce rate too, or a throttled burst
  reads as clean.

## What gets built in this lane

Reused, not rebuilt: `bulk_queue.py` (durable queue, at-most-once per key, triggers), the email route's
in-pod batch send and template pin (`request_comms/channels.py`), the copy gate frame
`email-template:<key>@<sha256>` (one verdict per template), `need_asks.py` / `scale_drain.py` for who is
owed an ask, `credit_status_uvn_ask` (already a `notify` template in muso-messaging).

New: the people builder for the ask stage (never asked first, paid first), a ramp controller (100/min,
doubling after each clean 10-minute window, holding on hard bounce, soft bounce, complaint, a gateway
pause or a ceiling refusal), a per-minute ledger read-back, and workers that run off node-8 under a
memory cap.

It ships unarmed, like the queue it extends. Reaching the contract's outcome on real mail needs the two
decisions above; neither is this lane's to take.

## Still unmeasured

- Per-send latency of `/v1/send` and what two gateway pods sustain.
- The rate Mailgun and the receiving providers accept from this domain.
- Distinct users behind the 71,204 never-asked requests.
- Whether a reply to `support@muso.ai` (the template's reply-to) is filed as proof by `credit-proof.py
  file-recent`.
