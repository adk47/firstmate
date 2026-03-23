#!/usr/bin/env python3
"""Generate enriched CSV payout report from Stripe matching Dashboard export + enrichment.

Usage: python3 payout_report.py <payout_id> [output_path]
"""

import subprocess, json, sys, csv, os, re
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

PRODUCT_MAP = {
    "prod_OFVYGPlM6SjHS6": ("Pro Plan", "credits"),
    "prod_OFVYBKkzV3ypza": ("Business Plan", "credits"),
    "prod_OQkgKKXueCq0lx": ("Business Users", "credits"),
    "prod_PcGpC7Gx0TGDoi": ("Business Standard", "credits"),
    "prod_OtKrovSlpE2F5u": ("Business Organizations", "credits"),
    "prod_QpaR84bNz6Lowf": ("Bulk Data Feed", "data"),
    "prod_QGlZaUBpcGgdTj": ("API Access", "api"),
    "prod_PTA688bEd27VRI": ("Plaque - XXL", "plaque"),
    "prod_PTA6znhrpsRYSp": ("Plaque - Regular", "plaque"),
    "prod_PBYCirvRodDchJ": ("Black Card", "credits"),
    "prod_PBY9XQpBPWRmTi": ("Encore Plaque - XXL", "plaque"),
    "prod_PBY8zZqSGpHiKU": ("Encore Plaque - Regular", "plaque"),
    "prod_NSSmCaFzYxFRoX": ("Muso.AI Team", "credits"),
    "prod_JrdIxhemt05eeH": ("Muso.AI Pro", "credits"),
}
TIER_RE = re.compile(r'Tier\s+(\d+)', re.IGNORECASE)

def stripe_cmd(resource, *args):
    cmd = ["stripe", resource] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(f"stripe error: {r.stderr[:200]}")
    return json.loads(r.stdout)

def get_balance_transactions(payout_id):
    txns, starting_after = [], None
    while True:
        args = ["list", "--limit", "100", "-d", f"payout={payout_id}"]
        if starting_after:
            args += ["-d", f"starting_after={starting_after}"]
        data = stripe_cmd("balance_transactions", *args)
        batch = data.get("data", [])
        txns.extend(batch)
        if not data.get("has_more") or not batch:
            break
        starting_after = batch[-1]["id"]
        print(f"  ...fetched {len(txns)} balance transactions", file=sys.stderr)
    return txns

def classify_product(product_id, line_desc):
    product_name, business_line = PRODUCT_MAP.get(product_id, ("Unknown", "credits"))
    tier = ""
    if line_desc:
        m = TIER_RE.search(line_desc)
        if m:
            tier = f"Tier {m.group(1)}"
    if not tier:
        nl = product_name.lower()
        if "business" in nl: tier = "business"
        elif "pro" in nl: tier = "pro"
        elif "plaque" in nl: tier = "plaque"
    return product_name, business_line, tier

def enrich_charge(charge_id):
    try:
        charge = stripe_cmd("charges", "retrieve", charge_id,
                           "-d", "expand[]=customer", "-d", "expand[]=invoice")
    except Exception:
        return {}
    result = {}
    cust = charge.get("customer")
    if isinstance(cust, dict):
        result["customer_id"] = cust.get("id", "")
        result["customer_email"] = cust.get("email", "") or ""
        result["customer_name"] = cust.get("name", "") or ""
    else:
        result["customer_id"] = cust or ""
        bd = charge.get("billing_details", {})
        result["customer_email"] = bd.get("email", "") or charge.get("receipt_email", "") or ""
        result["customer_name"] = bd.get("name", "") or ""
    result["metadata"] = charge.get("metadata", {}) or {}
    result["description"] = charge.get("description", "") or ""

    product_name, business_line, tier = "", "credits", ""
    invoice = charge.get("invoice")
    if isinstance(invoice, dict):
        lines = invoice.get("lines", {}).get("data", [])
        best_line, best_amt = None, -1
        for line in lines:
            a = abs(line.get("amount", 0))
            if a > best_amt:
                best_amt, best_line = a, line
        if best_line:
            price = best_line.get("price", {}) or {}
            pid = price.get("product", "") or ""
            desc = best_line.get("description", "") or ""
            product_name, business_line, tier = classify_product(pid, desc)
    if not product_name:
        product_name = result["description"] or "Unknown"
    result["product_name"] = product_name
    result["business_line"] = business_line
    result["tier"] = tier
    return result

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 payout_report.py <payout_id> [output_path]", file=sys.stderr)
        sys.exit(1)

    payout_id = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else f"/tmp/payout_{payout_id[-6:]}.csv"

    print(f"Fetching balance transactions for {payout_id}...", file=sys.stderr)
    txns = get_balance_transactions(payout_id)

    charge_txns = [t for t in txns if t["type"] in ("charge", "payment")]
    refund_txns = [t for t in txns if t["type"] == "refund"]
    fee_txns = [t for t in txns if t["type"] not in ("charge", "payment", "refund", "payout")]
    all_enrichable = charge_txns + refund_txns
    total = len(all_enrichable)
    print(f"Found {len(txns)} transactions ({len(charge_txns)} charges, {len(refund_txns)} refunds, {len(fee_txns)} fees). Enriching...", file=sys.stderr)

    # Resolve refund → charge mapping
    refund_charge_map = {}
    for t in refund_txns:
        src = t.get("source", "")
        if src.startswith("re_"):
            try:
                ref = stripe_cmd("refunds", "retrieve", src)
                refund_charge_map[src] = ref.get("charge", "")
            except Exception:
                pass

    # Enrich charges in parallel (5 workers to not overwhelm CLI)
    charge_ids = set()
    for t in charge_txns:
        s = t.get("source", "")
        if s.startswith(("ch_", "py_")):
            charge_ids.add(s)
    for cid in refund_charge_map.values():
        if cid:
            charge_ids.add(cid)

    enrichments = {}
    done = 0
    with ThreadPoolExecutor(max_workers=5) as pool:
        futures = {pool.submit(enrich_charge, cid): cid for cid in charge_ids}
        for f in as_completed(futures):
            cid = futures[f]
            try:
                enrichments[cid] = f.result()
            except Exception:
                enrichments[cid] = {}
            done += 1
            if done % 50 == 0:
                print(f"  ...enriched {done}/{len(charge_ids)}", file=sys.stderr)
    print(f"  ...enriched {done}/{len(charge_ids)} (done)", file=sys.stderr)

    FIELDS = [
        "Type", "ID", "Created", "Description", "Amount", "Currency",
        "Converted Amount", "Fees", "Net", "Converted Currency", "Details",
        "Customer ID", "Customer Email", "Customer Name",
        "Address_Validation_Status (metadata)", "Coupon (metadata)",
        "Referral deactivated (metadata)", "referral (metadata)",
        "Campaign (metadata)", "View in Rewardful (metadata)",
        "Affiliate (metadata)", "Link (metadata)",
        "userId (metadata)", "teamId (metadata)",
        "product_name", "business_line", "tier",
    ]

    rows = []
    for t in all_enrichable:
        src = t.get("source", "")
        ttype = t.get("type", "")
        amt = t.get("amount", 0) / 100
        fee = t.get("fee", 0) / 100
        net = t.get("net", 0) / 100
        created = datetime.fromtimestamp(t.get("created", 0), tz=timezone.utc).strftime("%Y-%m-%d %H:%M")
        desc = t.get("description", "") or ""
        cur = t.get("currency", "usd")

        cid = src
        if ttype == "refund":
            cid = refund_charge_map.get(src, src)
        en = enrichments.get(cid, {})
        meta = en.get("metadata", {})

        type_label = "Charge" if ttype in ("charge", "payment") else "Refund"

        rows.append({
            "Type": type_label,
            "ID": src,
            "Created": created,
            "Description": desc or en.get("description", ""),
            "Amount": f"{amt:.2f}",
            "Currency": cur,
            "Converted Amount": f"{amt:.2f}",
            "Fees": f"{fee:.2f}",
            "Net": f"{net:.2f}",
            "Converted Currency": cur,
            "Details": en.get("customer_email", ""),
            "Customer ID": en.get("customer_id", ""),
            "Customer Email": en.get("customer_email", ""),
            "Customer Name": en.get("customer_name", ""),
            "Address_Validation_Status (metadata)": meta.get("Address_Validation_Status", ""),
            "Coupon (metadata)": meta.get("Coupon", ""),
            "Referral deactivated (metadata)": meta.get("Referral deactivated", ""),
            "referral (metadata)": meta.get("referral", ""),
            "Campaign (metadata)": meta.get("Campaign", ""),
            "View in Rewardful (metadata)": meta.get("View in Rewardful", ""),
            "Affiliate (metadata)": meta.get("Affiliate", ""),
            "Link (metadata)": meta.get("Link", ""),
            "userId (metadata)": meta.get("userId", ""),
            "teamId (metadata)": meta.get("teamId", ""),
            "product_name": en.get("product_name", ""),
            "business_line": en.get("business_line", ""),
            "tier": en.get("tier", ""),
        })

    # Non-charge/refund rows: preserve original Stripe type (Stripe Fee, Adjustment, etc.)
    TYPE_LABEL_MAP = {
        "stripe_fee": "Stripe Fee",
        "adjustment": "Adjustment",
        "network_cost": "Network Cost",
        "network_risk_fee": "Network Risk Fee",
    }
    for t in fee_txns:
        amt = t.get("amount", 0) / 100
        fee = t.get("fee", 0) / 100
        net = t.get("net", 0) / 100
        created = datetime.fromtimestamp(t.get("created", 0), tz=timezone.utc).strftime("%Y-%m-%d %H:%M")
        raw_type = t.get("type", "")
        type_label = TYPE_LABEL_MAP.get(raw_type, raw_type.replace("_", " ").title() if raw_type else "Stripe Fee")
        row = {f: "" for f in FIELDS}
        row.update({
            "Type": type_label,
            "ID": t.get("source", ""),
            "Created": created,
            "Description": t.get("description", "") or "",
            "Amount": f"{amt:.2f}",
            "Currency": t.get("currency", "usd"),
            "Converted Amount": f"{amt:.2f}",
            "Fees": f"{fee:.2f}",
            "Net": f"{net:.2f}",
            "Converted Currency": t.get("currency", "usd"),
        })
        rows.append(row)

    with open(output_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)

    print(f"\nWrote {len(rows)} rows to {output_path}", file=sys.stderr)
    print(os.path.abspath(output_path))

if __name__ == "__main__":
    main()
