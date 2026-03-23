#!/bin/bash
# Generate the REAL payout reconciliation report with appended product info
# Mirrors Stripe's default columns + product_name, business_line, tier
set -euo pipefail

PAYOUT_ID="${1:?Usage: $0 <payout_id>}"
OUTFILE="/tmp/payout_report_${PAYOUT_ID}.csv"
CACHE_FILE="/tmp/.prod_cache_$$"
: > "$CACHE_FILE"
trap 'rm -f "$CACHE_FILE"' EXIT

get_product_info() {
  local prod_id="$1"
  local cached
  cached=$(grep "^${prod_id}|" "$CACHE_FILE" 2>/dev/null | head -1 || true)
  if [ -n "$cached" ]; then
    echo "${cached#*|}"
    return
  fi
  local prod_json name biz tier
  prod_json=$(stripe products retrieve "$prod_id" 2>/dev/null || echo '{}')
  name=$(echo "$prod_json" | jq -r '.name // ""')
  biz=$(echo "$prod_json" | jq -r '.metadata.business_line // ""')
  tier=$(echo "$prod_json" | jq -r '.metadata.tier // ""')
  echo "${prod_id}|${name}|${biz}|${tier}" >> "$CACHE_FILE"
  echo "${name}|${biz}|${tier}"
}

echo "Fetching payout ${PAYOUT_ID}..." >&2
PAYOUT=$(stripe payouts retrieve "$PAYOUT_ID" 2>/dev/null)
P_AMOUNT=$(echo "$PAYOUT" | jq -r '.amount')
P_ARRIVAL=$(echo "$PAYOUT" | jq -r '.arrival_date')
P_CREATED=$(echo "$PAYOUT" | jq -r '.created')
P_STATUS=$(echo "$PAYOUT" | jq -r '.status')
P_ARRIVAL_DATE=$(date -r "$P_ARRIVAL" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$P_ARRIVAL")

echo "Payout: \$$(echo "scale=2; ${P_AMOUNT} / 100" | bc) | Arrival: ${P_ARRIVAL_DATE} | Status: ${P_STATUS}" >&2

# CSV header — mirrors Stripe's default payout reconciliation + 3 appended columns
echo '"automatic_payout_id","automatic_payout_effective_at","balance_transaction_id","created","available_on","currency","gross","fee","net","reporting_category","source_id","description","customer_facing_amount","customer_facing_currency","customer_id","customer_email","product_name","business_line","tier"' > "$OUTFILE"

# Paginate through all balance transactions for this payout
STARTING_AFTER=""
HAS_MORE=true
TOTAL=0

while [ "$HAS_MORE" = "true" ]; do
  if [ -z "$STARTING_AFTER" ]; then
    PAGE=$(stripe balance_transactions list -d "payout=$PAYOUT_ID" -d "limit=100" -d "expand[]=data.source" 2>/dev/null)
  else
    PAGE=$(stripe balance_transactions list -d "payout=$PAYOUT_ID" -d "limit=100" -d "starting_after=$STARTING_AFTER" -d "expand[]=data.source" 2>/dev/null)
  fi
  
  HAS_MORE=$(echo "$PAGE" | jq -r '.has_more')
  STARTING_AFTER=$(echo "$PAGE" | jq -r '.data[-1].id // empty')
  COUNT=$(echo "$PAGE" | jq -r '.data | length')
  
  echo "$PAGE" | jq -c '.data[]' | while read -r BT; do
    BT_ID=$(echo "$BT" | jq -r '.id')
    BT_CREATED_TS=$(echo "$BT" | jq -r '.created')
    BT_AVAIL_TS=$(echo "$BT" | jq -r '.available_on')
    BT_CURRENCY=$(echo "$BT" | jq -r '.currency')
    BT_AMOUNT=$(echo "$BT" | jq -r '.amount')
    BT_FEE=$(echo "$BT" | jq -r '.fee')
    BT_NET=$(echo "$BT" | jq -r '.net')
    BT_TYPE=$(echo "$BT" | jq -r '.reporting_category // .type')
    BT_SOURCE=$(echo "$BT" | jq -r '.source // ""')
    BT_DESC=$(echo "$BT" | jq -r '.description // ""' | sed 's/"/""/g')
    
    # Handle source as string (ID) or object (expanded)
    SOURCE_ID=""
    if echo "$BT_SOURCE" | jq -e '.id' >/dev/null 2>&1; then
      SOURCE_ID=$(echo "$BT_SOURCE" | jq -r '.id')
    else
      SOURCE_ID="$BT_SOURCE"
    fi
    
    BT_CREATED_DATE=$(date -r "$BT_CREATED_TS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$BT_CREATED_TS")
    BT_AVAIL_DATE=$(date -r "$BT_AVAIL_TS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$BT_AVAIL_TS")
    
    GROSS=$(echo "scale=2; ${BT_AMOUNT} / 100" | bc)
    FEE_USD=$(echo "scale=2; ${BT_FEE} / 100" | bc)
    NET_USD=$(echo "scale=2; ${BT_NET} / 100" | bc)
    
    PROD_NAME=""
    BIZ_LINE=""
    TIER_VAL=""
    CUST_ID=""
    CUST_EMAIL=""
    CF_AMOUNT=""
    CF_CURRENCY=""
    
    # Enrich charges with product info
    if echo "$SOURCE_ID" | grep -q "^ch_"; then
      CHARGE=$(stripe charges retrieve "$SOURCE_ID" 2>/dev/null || echo '{}')
      CUST_ID=$(echo "$CHARGE" | jq -r '.customer // ""')
      CUST_EMAIL=$(echo "$CHARGE" | jq -r '.billing_details.email // .receipt_email // ""')
      CF_AMOUNT=$(echo "$CHARGE" | jq -r '.amount // ""')
      CF_CURRENCY=$(echo "$CHARGE" | jq -r '.currency // ""')
      INV_ID=$(echo "$CHARGE" | jq -r '.invoice // ""')
      
      if [ -n "$CF_AMOUNT" ] && [ "$CF_AMOUNT" != "null" ] && [ "$CF_AMOUNT" != "" ]; then
        CF_AMOUNT=$(echo "scale=2; ${CF_AMOUNT} / 100" | bc)
      fi
      
      if [ -n "$INV_ID" ] && [ "$INV_ID" != "null" ]; then
        INV=$(stripe invoices retrieve "$INV_ID" 2>/dev/null || echo '{}')
        PRODUCT_ID=$(echo "$INV" | jq -r '.lines.data[0].price.product // ""')
        if [ -n "$PRODUCT_ID" ] && [ "$PRODUCT_ID" != "null" ] && [ "$PRODUCT_ID" != "" ]; then
          INFO=$(get_product_info "$PRODUCT_ID")
          PROD_NAME=$(echo "$INFO" | cut -d'|' -f1)
          BIZ_LINE=$(echo "$INFO" | cut -d'|' -f2)
          TIER_VAL=$(echo "$INFO" | cut -d'|' -f3)
        fi
      fi
    fi
    
    echo "\"${PAYOUT_ID}\",\"${P_ARRIVAL_DATE}\",\"${BT_ID}\",\"${BT_CREATED_DATE}\",\"${BT_AVAIL_DATE}\",\"${BT_CURRENCY}\",\"${GROSS}\",\"${FEE_USD}\",\"${NET_USD}\",\"${BT_TYPE}\",\"${SOURCE_ID}\",\"${BT_DESC}\",\"${CF_AMOUNT}\",\"${CF_CURRENCY}\",\"${CUST_ID}\",\"${CUST_EMAIL}\",\"${PROD_NAME}\",\"${BIZ_LINE}\",\"${TIER_VAL}\"" >> "$OUTFILE"
  done
  
  TOTAL=$((TOTAL + COUNT))
  echo "  Processed ${TOTAL} transactions..." >&2
  
  [ "$HAS_MORE" = "false" ] && break
done

ROWS=$(($(wc -l < "$OUTFILE") - 1))
echo "Done! ${ROWS} transactions in ${OUTFILE}" >&2
echo "$OUTFILE"
