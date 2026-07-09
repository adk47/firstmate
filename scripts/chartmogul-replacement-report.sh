#!/usr/bin/env bash
# ChartMogul replacement subscription report.
#
# Read-only. Emits Slack-ready mrkdwn for Aaron's daily DM cron.
# Sources:
#   - Stripe API for Stripe subscriptions and Stripe MRR movement.
#   - Live core Postgres, queried from a prod core-backend pod, for
#     non-Stripe subscriptions that Stripe cannot see.
set -uo pipefail

if [ -r /etc/openclaw/main.env ]; then
  set -a
  # shellcheck disable=SC1091
  . /etc/openclaw/main.env
  set +a
fi

python3 - "$@" <<'PY'
import argparse
import json
import os
import subprocess
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo

import stripe

REPORT_TZ = os.environ.get("CHARTMOGUL_REPLACEMENT_TZ", "America/Chicago")
KUBE_NS = os.environ.get("CHARTMOGUL_REPLACEMENT_KUBE_NS", "muso-prod")
POD_PREFIX = os.environ.get("CHARTMOGUL_REPLACEMENT_POD_PREFIX", "core-backend-api")


def fail(title, detail, code=1):
    print(f"*{title}*")
    print()
    print("```")
    print(str(detail).strip())
    print("```")
    raise SystemExit(code)


def money(v):
    return f"${float(v):,.2f}"


def signed_money(v):
    v = float(v)
    return f"+${v:,.2f}" if v >= 0 else f"-${abs(v):,.2f}"


def pct(v):
    return f"{float(v):.2f}%"


def month_factor(price):
    recurring = getattr(price, "recurring", None) or {}
    interval = recurring.get("interval") if isinstance(recurring, dict) else getattr(recurring, "interval", None)
    interval_count = recurring.get("interval_count") if isinstance(recurring, dict) else getattr(recurring, "interval_count", None)
    interval_count = interval_count or 1
    if interval == "year":
        return 1.0 / (12.0 * interval_count)
    if interval == "month":
        return 1.0 / interval_count
    if interval == "week":
        return 52.0 / 12.0 / interval_count
    if interval == "day":
        return 365.0 / 12.0 / interval_count
    return 1.0


def cents_value(obj, *names):
    for name in names:
        val = getattr(obj, name, None)
        if val is not None:
            return float(val)
    return 0.0


class StripeReader:
    def __init__(self):
        key = os.environ.get("MUSOAI_STRIPE_API_KEY")
        if not key:
            fail("ChartMogul replacement report failed", "MUSOAI_STRIPE_API_KEY is not set")
        stripe.api_key = key
        self.price_cache = {}

    def price(self, price_id):
        if not price_id:
            return None
        if price_id not in self.price_cache:
            self.price_cache[price_id] = stripe.Price.retrieve(price_id, expand=["tiers"])
        return self.price_cache[price_id]

    def tier_amount_cents(self, price, quantity):
        quantity = int(quantity or 1)
        tiers = getattr(price, "tiers", None) or []
        if not tiers:
            return 0.0
        mode = getattr(price, "tiers_mode", None) or "graduated"

        def tier_unit(t):
            return cents_value(t, "unit_amount_decimal", "unit_amount")

        def tier_flat(t):
            return cents_value(t, "flat_amount_decimal", "flat_amount")

        if mode == "volume":
            selected = tiers[-1]
            for tier in tiers:
                up_to = getattr(tier, "up_to", None)
                if up_to is None or quantity <= int(up_to):
                    selected = tier
                    break
            return tier_flat(selected) + tier_unit(selected) * quantity

        remaining = quantity
        previous = 0
        total = 0.0
        for tier in tiers:
            if remaining <= 0:
                break
            up_to = getattr(tier, "up_to", None)
            tier_cap = quantity if up_to is None else int(up_to)
            units = max(0, min(quantity, tier_cap) - previous)
            if units > 0:
                total += tier_flat(tier) + tier_unit(tier) * units
                remaining -= units
            previous = tier_cap
        return total

    def item_mrr(self, item):
        quantity = int(getattr(item, "quantity", None) or item.get("quantity", 1) or 1)
        inline_price = getattr(item, "price", None) or item.get("price")
        if not inline_price:
            return 0.0, "unknown", "unknown"
        price_id = getattr(inline_price, "id", None) or inline_price.get("id")
        price = self.price(price_id)
        if not price:
            return 0.0, "unknown", "unknown"

        if getattr(price, "billing_scheme", None) == "tiered":
            cents = self.tier_amount_cents(price, quantity)
        else:
            cents = cents_value(price, "unit_amount_decimal", "unit_amount") * quantity
        mrr = cents / 100.0 * month_factor(price)

        lookup = getattr(price, "lookup_key", None) or ""
        nickname = getattr(price, "nickname", None) or ""
        label = lookup or nickname or price_id or "unknown"
        category_src = f"{lookup} {nickname}".lower()
        if "business" in category_src:
            category = "business"
        elif "pro" in category_src:
            category = "pro"
        else:
            category = "other"
        return mrr, label, category

    def subscription_mrr(self, sub):
        total = 0.0
        by_label = defaultdict(float)
        by_category = defaultdict(float)
        items_obj = sub.get("items", {}) if hasattr(sub, "get") else {}
        items = (items_obj or {}).get("data", [])
        for item in items:
            mrr, label, category = self.item_mrr(item)
            total += mrr
            by_label[label] += mrr
            by_category[category] += mrr
        return total, by_label, by_category

    def active(self):
        return list(stripe.Subscription.list(status="active", limit=100).auto_paging_iter())

    def events_since(self, event_type, since_ts):
        return list(stripe.Event.list(type=event_type, created={"gte": since_ts}, limit=100).auto_paging_iter())


def find_core_pod():
    proc = subprocess.run(["kubectl", "-n", KUBE_NS, "get", "pods", "--no-headers"], text=True, capture_output=True, check=True)
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].startswith(POD_PREFIX) and parts[2] == "Running":
            return parts[0]
    raise RuntimeError(f"no running {POD_PREFIX} pod found in namespace {KUBE_NS}")


def pg_non_stripe():
    pod = find_core_pod()
    node_script = r'''
const { Client } = require('pg');
const sql = `
WITH priced AS (
  SELECT
    service,
    status,
    plan,
    "createdAt",
    "updatedAt",
    CASE
      WHEN plan = 'muso_individual_pro_monthly' OR plan = 'muso_individual_pro_monthly_notrial' THEN 12.50
      WHEN plan = 'muso_individual_pro_annual' THEN 10.00
      WHEN plan = 'muso_individual_proplus_monthly' OR plan = 'muso_individual_proplus_monthly_notrial' THEN 25.00
      WHEN plan = 'muso_individual_proplus_annual' THEN 20.00
      WHEN plan = 'muso_team_pro_graduated_monthly'
        THEN 12.50 + greatest(coalesce("profileSeatsLimit", 1) - 1, 0) * 7.50
      WHEN plan = 'muso_team_pro_graduated_annual'
        THEN (120.00 + greatest(coalesce("profileSeatsLimit", 1) - 1, 0) * 72.00) / 12.0
      ELSE 0.00
    END AS est_mrr
  FROM subscriptions
  WHERE service IN ('app_store', 'google_play', 'paypal')
    AND coalesce(plan, '') NOT IN ('vip', 'boomer', 'custom', '')
),
current_rows AS (
  SELECT service, plan, count(*)::int AS active_subs, round(sum(est_mrr)::numeric, 2)::float AS mrr
  FROM priced
  WHERE status = 'active'
  GROUP BY service, plan
),
movement_rows AS (
  SELECT
    period,
    count(*) FILTER (WHERE "createdAt" >= start_ts)::int AS new_subs,
    round(coalesce(sum(CASE WHEN "createdAt" >= start_ts THEN est_mrr ELSE 0 END), 0)::numeric, 2)::float AS new_mrr,
    count(*) FILTER (WHERE status = 'cancelled' AND "updatedAt" >= start_ts)::int AS churned_subs,
    round(coalesce(sum(CASE WHEN status = 'cancelled' AND "updatedAt" >= start_ts THEN est_mrr ELSE 0 END), 0)::numeric, 2)::float AS churned_mrr
  FROM priced
  CROSS JOIN (
    VALUES
      ('today', date_trunc('day', now())),
      ('week_to_date', date_trunc('week', now())),
      ('month_to_date', date_trunc('month', now())),
      ('last_30_days', date_trunc('day', now()) - interval '30 days')
  ) AS windows(period, start_ts)
  GROUP BY period
)
SELECT json_build_object(
  'current', (SELECT coalesce(json_agg(current_rows), '[]'::json) FROM current_rows),
  'movement', (SELECT coalesce(json_agg(movement_rows), '[]'::json) FROM movement_rows)
) AS report;
`;
(async () => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const res = await client.query(sql);
  console.log(JSON.stringify(res.rows[0].report));
  await client.end();
})().catch(e => {
  console.error(e.stack || e.message);
  process.exit(1);
});
'''
    proc = subprocess.run(["kubectl", "-n", KUBE_NS, "exec", "-i", pod, "--", "node", "-"], input=node_script, text=True, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "core PG query failed")
    return json.loads(proc.stdout)


def empty_move():
    return {"new_subs": 0, "new_mrr": 0.0, "churned_subs": 0, "churned_mrr": 0.0}


def add_move(dst, period, new_subs=0, new_mrr=0.0, churned_subs=0, churned_mrr=0.0):
    row = dst.setdefault(period, empty_move())
    row["new_subs"] += int(new_subs)
    row["new_mrr"] += float(new_mrr)
    row["churned_subs"] += int(churned_subs)
    row["churned_mrr"] += float(churned_mrr)


def period_for(ts, starts):
    return [name for name, start in starts.items() if ts >= start]


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["daily", "weekly", "monthly"], default="daily")
    return parser.parse_args()


def main():
    args = parse_args()
    now = datetime.now(timezone.utc)
    local_now = now.astimezone(ZoneInfo(REPORT_TZ))
    local_midnight = local_now.replace(hour=0, minute=0, second=0, microsecond=0)
    local_week_start = (local_midnight - timedelta(days=local_midnight.weekday()))
    local_month_start = local_midnight.replace(day=1)
    starts_dt = {
        "today": local_midnight.astimezone(timezone.utc),
        "week_to_date": local_week_start.astimezone(timezone.utc),
        "month_to_date": local_month_start.astimezone(timezone.utc),
        "last_30_days": (local_midnight - timedelta(days=30)).astimezone(timezone.utc),
    }
    starts_ts = {k: int(v.timestamp()) for k, v in starts_dt.items()}

    sr = StripeReader()
    active_subs = sr.active()

    stripe_current_mrr = 0.0
    stripe_category_mrr = defaultdict(float)
    stripe_plan_mrr = defaultdict(float)
    for sub in active_subs:
        mrr, by_label, by_category = sr.subscription_mrr(sub)
        stripe_current_mrr += mrr
        for k, v in by_label.items():
            stripe_plan_mrr[k] += v
        for k, v in by_category.items():
            stripe_category_mrr[k] += v

    movement = {}
    min_start = min(starts_ts.values())
    seen_new = set()
    for event in sr.events_since("customer.subscription.created", min_start):
        sub = event.data.object
        sub_id = getattr(sub, "id", None) or sub.get("id")
        if sub_id in seen_new:
            continue
        seen_new.add(sub_id)
        mrr, _, _ = sr.subscription_mrr(sub)
        for period in period_for(int(event.created), starts_ts):
            add_move(movement, period, new_subs=1, new_mrr=mrr)

    seen_churn = set()
    for event in sr.events_since("customer.subscription.deleted", min_start):
        sub = event.data.object
        sub_id = getattr(sub, "id", None) or sub.get("id")
        if sub_id in seen_churn:
            continue
        seen_churn.add(sub_id)
        mrr, _, _ = sr.subscription_mrr(sub)
        for period in period_for(int(event.created), starts_ts):
            add_move(movement, period, churned_subs=1, churned_mrr=mrr)

    pg = pg_non_stripe()
    pg_current_mrr = 0.0
    pg_active_subs = 0
    pg_plan_mrr = defaultdict(float)
    pg_category_mrr = defaultdict(float)
    for row in pg.get("current", []):
        mrr = float(row.get("mrr") or 0.0)
        subs = int(row.get("active_subs") or 0)
        plan = row.get("plan") or "unknown"
        service = row.get("service") or "unknown"
        label = f"{service}:{plan}"
        pg_current_mrr += mrr
        pg_active_subs += subs
        pg_plan_mrr[label] += mrr
        plan_l = plan.lower()
        if "business" in plan_l:
            pg_category_mrr["business"] += mrr
        elif "pro" in plan_l:
            pg_category_mrr["pro"] += mrr
        else:
            pg_category_mrr["other"] += mrr

    for row in pg.get("movement", []):
        add_move(
            movement,
            row["period"],
            new_subs=row.get("new_subs") or 0,
            new_mrr=row.get("new_mrr") or 0.0,
            churned_subs=row.get("churned_subs") or 0,
            churned_mrr=row.get("churned_mrr") or 0.0,
        )

    total_mrr = stripe_current_mrr + pg_current_mrr
    total_active = len(active_subs) + pg_active_subs
    total_arr = total_mrr * 12.0
    arpa = total_mrr / total_active if total_active else 0.0
    pro_mrr = stripe_category_mrr["pro"] + pg_category_mrr["pro"]
    business_mrr = stripe_category_mrr["business"] + pg_category_mrr["business"]

    title = {
        "daily": "Daily ChartMogul replacement report",
        "weekly": "Weekly ChartMogul replacement report",
        "monthly": "Monthly ChartMogul replacement report",
    }[args.mode]
    print(f"*{title}* - {local_now.strftime('%Y-%m-%d %I:%M %p %Z')}")
    print("_Sources: Stripe API for Stripe subscriptions and movement; live core Postgres for Apple/Google/PayPal. Local reporting window: `America/Chicago`. Excludes `vip`, `boomer`, and `custom`._")
    print()
    print("*Current*")
    print(f"MRR: *{money(total_mrr)}* | ARR: *{money(total_arr)}*")
    print(f"Active paid subs: *{total_active:,}* | ARPA: *{money(arpa)}*")
    print(f"Stripe MRR: *{money(stripe_current_mrr)}* | non-Stripe MRR: *{money(pg_current_mrr)}*")
    print(f"Pro MRR: *{money(pro_mrr)}* | Business MRR: *{money(business_mrr)}*")
    print()

    labels = {
        "today": "Daily / Today",
        "week_to_date": f"Weekly / WTD from {local_week_start.strftime('%b %-d')} CDT",
        "month_to_date": f"Monthly / MTD from {local_month_start.strftime('%b %-d')} CDT",
        "last_30_days": "Last 30 days",
    }
    for period in ["today", "week_to_date", "month_to_date", "last_30_days"]:
        row = movement.get(period, empty_move())
        net = float(row["new_mrr"]) - float(row["churned_mrr"])
        churn_rate = (float(row["churned_subs"]) / total_active * 100.0) if total_active else 0.0
        print(f"*{labels[period]}*")
        print(f"New: *{int(row['new_subs']):,} subs* / *{signed_money(row['new_mrr'])} MRR*")
        print("Reactivated: *not tracked in recovered script* / *+$0.00 MRR*")
        print("Expansion: *+$0.00 MRR* | contraction: *-$0.00 MRR*")
        print(f"Churn: *{int(row['churned_subs']):,} subs* / *-{money(row['churned_mrr'])} MRR*")
        print(f"Net: *{signed_money(net)} MRR* | churn rate: *{pct(churn_rate)}*")
        print()

    combined_plans = defaultdict(float)
    for k, v in stripe_plan_mrr.items():
        combined_plans[k] += v
    for k, v in pg_plan_mrr.items():
        combined_plans[k] += v
    print("*Top active prices/plans*")
    for label, mrr in sorted(combined_plans.items(), key=lambda kv: kv[1], reverse=True)[:8]:
        print(f"- `{label}`: *{money(mrr)} MRR*")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:
        fail("ChartMogul replacement report failed", exc)
PY
