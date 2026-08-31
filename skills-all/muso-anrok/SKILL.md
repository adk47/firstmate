---
name: muso-anrok
description: |
  USE THIS for Muso.AI's Anrok sales-tax / VAT compliance: calculate tax on Stripe
  invoices, create/update/void/negate transactions, manage exemption certificates,
  product mappings, and list filings. ACCESS-GATED: write access is Aaron (U7RP6HKUZ)
  ONLY, read access is Liza (U0A8CCTTAAG) — everyone else is blocked; direct them to Aaron.
---

# Anrok — Sales Tax & VAT Compliance

Anrok is Muso.AI's global sales tax and VAT solution for SaaS. Handles tax calculation, filing, returns, and compliance.

## Access Control

- **WRITE access:** Aaron (U7RP6HKUZ) ONLY — create/update transactions, void, negate, manage certificates, add product mappings
- **READ access:** Liza (U0A8CCTTAAG) — list transactions, filings, product mappings
- **Everyone else:** BLOCKED entirely. Direct them to Aaron.

## API Reference

- **API base:** `https://api.anrok.com/v1/seller/`
- **Auth:** `Authorization: Bearer $ANROK_API_KEY` (key format: `{sellerId}/{apiKeyId}/secret.{secret}`)
- **All requests are HTTP POST** with JSON body (even reads)
- **Rate limit:** 10 requests/second per seller account
- **Seller ID:** `s3rcakf85jf` (embedded in the API key)
- **App URL:** `https://app.anrok.com/s3rcakf85jf/`
- **API docs:** `https://apidocs.anrok.com` (OpenAPI v1.1 spec, Redoc)
- **Tutorials:** `https://apidocs.anrok.com/tutorials/`
- **Help center:** `https://help-center.anrok.com`
- **Wrapper:** `bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-anrok/scripts/anrok-api.sh <endpoint> [json-body] [jq-filter]`

## Endpoints (Complete — from official API docs)

### Customer Certificates

| Operation | Endpoint | Method | Description |
|-----------|----------|--------|-------------|
| Create | `certificates/create` | POST | Create exemption certificate |
| Archive | `certificates/id:{certificateId}/archive` | POST | Archive/invalidate a certificate |

**Create certificate body:**
```json
{
  "customerId": "cus_123",           // required
  "customerName": "Acme Inc",
  "effectiveDateBegin": "2022-01-01", // required, date
  "exemptionNumber": "cert-100",
  "certificateFile": {                // required
    "name": "cert.png",
    "contentsBase64": "base64data"
  },
  "jurises": [{ ... }]               // required, jurisdictions
}
```

### Transactions

| Operation | Endpoint | Method | Description |
|-----------|----------|--------|-------------|
| Create/Update | `transactions/createOrUpdate` | POST | Create or update a finalized transaction (saved, used for returns) |
| Ephemeral | `transactions/createEphemeral` | POST | Tax estimate preview (NOT saved, NOT used for returns) |
| Negate | `transactions/createNegation` | POST | Create inverse transaction (for refunds) |
| Void | `transactions/id:{transactionId}/void` | POST | Remove transaction from returns |
| List | `transactions/list` | POST | List transactions (⚠️ premium feature) |

**createOrUpdate body (required fields):**
```json
{
  "id": "stripe:in_xxx",              // required, unique across seller
  "lineItems": [{                      // required
    "productExternalId": "saas-product",
    "amount": 1050
  }],
  "currencyCode": "USD",              // required, 3-char ISO
  "customerAddress": {                 // required
    "country": "us",
    "line1": "310 S Houston St",
    "city": "Dallas",
    "region": "TX",                    // NOTE: use "region" not "state"
    "postalCode": "75202"
  }
}
```

**Optional transaction fields:**
- `customerName` — display only
- `customerId` — links transactions to same customer, looks up certificates
- `customerTaxIds` — array of `{type, value}` for VAT ID validation
- `shipFromAddress` — origin-based sourcing (defaults to Anrok business address)
- `accountingDate` — date string, determines which tax return
- `accountingTime` — ISO datetime, alternative to accountingDate
- `accountingTimeZone` — enum (UTC, America/Los_Angeles, etc.)
- `taxDate` — date for tax rate lookup (defaults to accountingDate)

**createEphemeral:** Same body as createOrUpdate but WITHOUT `id` field. Returns tax amounts without saving.

**createNegation body:**
```json
{
  "originalTransactionId": "stripe:in_xxx",     // required
  "newTransactionId": "stripe:in_xxx_refund",   // required
  "originalTransactionExpectedVersion": 1        // optional, version check
}
```

**void body:**
```json
{
  "transactionExpectedVersion": 1  // optional, version check
}
```

**list body:**
```json
{
  "filter": {
    "type": "lastModifiedAfter",     // or "filingInfo"
    "value": "2025-01-01T00:00:00Z"
  },
  "limit": 10,     // 1-20, default 10
  "cursor": "..."  // for pagination (from nextCursor)
}
```

**Response (createOrUpdate / createEphemeral):**
```json
{
  "version": 1,
  "taxAmountToCollect": 722,
  "lineItems": [{ "taxAmountToCollect": 69 }],
  "preTaxAmount": "68577.33",
  "jurisSummaries": [{ "id": "us-TX", "name": "Texas", ... }]
}
```

### Product Mappings (requires integrationId)

| Operation | Endpoint | Method | Description |
|-----------|----------|--------|-------------|
| List | `integrations/id:{integrationId}/productIdMapping/list` | POST | List all product ID mappings |
| Add | `integrations/id:{integrationId}/productIdMapping/add` | POST | Add a product ID mapping |

**Add mapping body:**
```json
{
  "sourceId": "billing-system-product-id",  // required
  "targetId": "anrok-product-id",           // required (must exist in Anrok)
  "shouldOverwrite": false                  // optional, default false
}
```

### Tax ID Validation (⚠️ premium feature)

| Operation | Endpoint | Method | Description |
|-----------|----------|--------|-------------|
| Validate | `taxId/validate` | POST | Validate customer tax IDs |

**Validate body:**
```json
{
  "customerAddress": {            // required
    "country": "CA",
    "line1": "123 Main St",
    "city": "Quebec City",
    "region": "Quebec",
    "postalCode": "G1P 2J6"
  },
  "customerTaxIds": [             // required (empty array to get required IDs)
    { "type": "ca_gst_hst", "value": "123456789RT0001" }
  ]
}
```

### Filings (⚠️ premium feature)

| Operation | Endpoint | Method | Description |
|-----------|----------|--------|-------------|
| List | `filings/list` | POST | List filings with optional filters |

**List filings body:**
```json
{
  "filter": {
    "jurisId": "us-MA",              // filter by jurisdiction
    "filingPeriodEndDateBegin": "2025-01-01",  // optional date range
    "filingPeriodEndDateEnd": "2025-12-31"
  },
  "limit": 10,     // 1-100, default 10
  "cursor": "..."  // for pagination
}
```

## Error Types

All errors return 400 with a JSON `{"type": "errorCode"}` body:
- `productExternalIdUnknown` — referenced product doesn't exist in Anrok
- `transactionFrozenForFiling` — can't update/void, already on a filed return
- `listTransactionsApiNotEnabled` — premium feature, contact hello@anrok.com
- `listFilingsApiNotEnabled` — premium feature, contact hello@anrok.com
- `customerAddressCouldNotResolve` — address too vague for tax jurisdiction

HTTP status codes: 200 OK, 400 Bad Request, 409 Conflict, 429 Too Many Requests

## Invoice Lifecycle (from Anrok docs)

1. **Invoice created** → call `createEphemeral` for tax preview
2. **Invoice updated** → call `createEphemeral` again
3. **Invoice finalized** → call `createOrUpdate` to save transaction
4. **Invoice paid** → no Anrok notification needed (tax remitted on invoice, not payment)
5. **Invoice voided** → call `void` to remove from returns
6. **Refund** → three options:
   - Update original with `createOrUpdate` (if not yet filed)
   - Create negative transaction with `createOrUpdate` (credit note style)
   - Negate original with `createNegation` + create new version

## Address Format

Use the **new format** (not legacy US-only):
```json
{
  "country": "us",       // ISO country code
  "line1": "123 Main St",
  "city": "Dallas",
  "region": "TX",        // state/province/region (NOT "state")
  "postalCode": "75202"  // (NOT "zipCode" — that's legacy format)
}
```

Legacy US-only format still works but uses `state` and `zipCode` instead.

## Integration Context

Anrok integrates with Stripe (Muso's billing provider). It can:
- Calculate tax on Stripe invoices automatically via built-in integration
- File and remit sales tax in registered US jurisdictions
- Handle global VAT/GST compliance
- Monitor nexus exposure from sales and employee locations
- Validate VAT IDs for international B2B transactions
