# Muso Ads Client Contracts

## Global Settings
- **Payment terms:** Due immediately (days_until_due=0) — payment upfront for activation
- **Statement descriptor:** "Muso.AI Ads" (pending — needs account-level setting in Stripe dashboard)
- **Products:** Muso Ads (`prod_U4kOhDrEttKAAz`, $1,250/mo `price_1T6axJLsjTo3Ar3lAMszw0eW`) | Muso Ads Boost (`prod_U4lnDYCQtVUjnx`, $1,250/mo `price_1T6cFaLsjTo3Ar3lHV9z6aSP`)

## IK Multimedia
- **Stripe Customer:** `cus_U4lg3wOjhQN29P`
- **Subscription:** `sub_1T6cX2LsjTo3Ar3lgvLHm5HU` (cancel_at_period_end=true)
- **Invoice:** `in_1T6cX2LsjTo3Ar3lD9kz8fSP` ($1,125, due immediately, sent 2026-03-02)
- **Contact:** Daniel Boatman (daniel.boatman@ikmultimedia.com)
- **CC:** Natalie Tauer (natalie.tauer@ikmultimedia.com)
- **Deal:** Single month trial, $1,250 base, 10% discount → $1,125/mo
- **Coupon:** `FAUcvyGQ` (10% off, once)
- **Contract type:** Single month trial (no long-term commitment)

## Kali Audio Inc.
- **Entity:** Kali Audio Inc., 201 North Hollywood Way, Suite 212, Burbank, CA 91505
- **Phone:** (818) 653-6222
- **Contacts:**
  - John Hovik Melikyan, Co-Founder/President (john.melikyan@kaliaudio.com, john@kaliaudio.com)
  - Nate Baglyos (nate.baglyos@kaliaudio.com)
- **Deal:** Early Adopter Bundle — 3-month commitment
  - Amp Listing ($1,250) + Boost ($1,250) + Complimentary Amp For You (US only, non-renewable)
  - 10% Early Adopter Discount → $2,250/mo ($6,750 total)
  - Category Exclusivity: Studio Monitors (MSRP < $5,000) during Commitment Period
- **Payment schedule:** $2,250/mo × 3, due immediately each month
- **Start date:** Platform launch (March 1, 2026)
- **Commitment:** 3 months, then month-to-month at full $2,500/mo
- **Contract signed:** John Melikyan 2/20/2026, Aaron Kaufman 2/24/2026
- **DocuSign:** `6FDED110-F666-4A8D-8692-F6849845CEE8`
- **Stripe Customer:** `cus_U4ll2CSQa7asSv`
- **Subscription:** `sub_1T6cXTLsjTo3Ar3lHRN5iunI` (month-to-month, due immediately)
- **Invoice #1:** `in_1T6cXTLsjTo3Ar3levtDMEYm` ($2,250, due immediately, sent 2026-03-02)
- **Coupon:** `DGOZ6GoZ` (10% off, repeating 3 months)

## Dutch & Dutch Ltd. (PENDING APPROVAL)
- **Entity:** Dutch & Dutch Ltd., Claes de Vrieselaan 164, 3021 JZ Rotterdam, The Netherlands
- **Contacts:**
  - Kevin Kleine, CEO (kevin.kleine@dutchdutch.com)
  - Jannis Dossis / JD (jd@dutchdutch.com) — authorized contact
- **Deal:** Early Adopter — 3-month commitment
  - Amp Listing ($1,250/mo), 10% discount → $1,125/mo
  - 20% off committed campaigns (3-month min, separate discount)
  - $3,375 pre-paid upon signing (3 × $1,125)
  - After commitment: auto-renews at $1,250/mo (no discount) until cancelled
- **Contract signed:** Kevin Kleine & Aaron Kaufman, both 2/24/2026
- **DocuSign:** `86BBF629-2ED0-4B27-A111-FD37E06E71D7`
- **Stripe Customer:** `cus_U4m0SkxfMLtuTh` (currently on aaron@muso.ai for testing)
- **Test invoice:** `in_1T6cVaLsjTo3Ar3ll2dewVYn` ($3,375, due immediately, sent to aaron@muso.ai)
- **Status:** Awaiting Aaron's approval before sending to Kevin/JD

## MWTM (Mixed With The Masters)
- **Company:** MWTM (Mixed With The Masters)
- **Contact:** Tom Bonnell (CMO)
- **Email:** tom@mwtm.com
- **Contract signed:** 2026-03-09 (both parties)
- **DocuSign Envelope:** 77F799E0-8F0F-46A7-B0B4-E62291DF5C1A
- **Service Commencement Date:** 2026-03-15 (anticipated)
- **Eligibility deadline:** 2026-03-06
- **Deal:**
  - Published calculator total: $20,426.00/mo (4 campaigns, CQS 76)
  - Elected: Month-to-month with Tier 5 EA (but off-tier negotiated rate)
  - Actually invoiced: $6,127.80/mo (70% off-tier, 3-month commitment rate applied m2m)
  - 12-month option: $5,106.50/mo (75% off-tier)
  - Month-to-month standard: $10,213.00/mo (50% Tier 5)
- **Campaigns:**
  1. Offer — Producers ($7,688/mo pre-discount): Amp + Amp For You + Feed
  2. Brand Awareness — Producers ($3,192/mo pre-discount): Amp For You
  3. Offer — Mixers ($4,773/mo pre-discount): Amp For You + Feed
  4. Brand Awareness — Mixers ($4,773/mo pre-discount): Amp For You + Feed
- **Targeting:** Producers, Composers, Engineers, Mixers — Global
- **Stripe IDs:**
  - Customer: `cus_U7LWj6IVJ9oh7z`
  - Subscription: `sub_1T96ppLsjTo3Ar3lSwANlyKn`
  - Price: `price_1T96pkLsjTo3Ar3lpb3r0GAD` ($6,127.80/mo)
  - Invoice #1: `in_1T96pqLsjTo3Ar3lXqjTWjWZ`
- **Status:** Invoice created, pending Aaron approval to send

## Slate Digital LLC
- **Entity:** Slate Digital LLC
- **Contact:** Jon Hillman — jonh@solidstatelogic.com
- **Contract:** Muso Ads Advertising Platform Agreement + Early Adopter Addendum (3-month commitment) + DPA
- **DocuSign Envelope:** BB3C60D0-A282-4DBA-B8FA-FA7E9C1B7EF7
- **Monthly amount:** $3,891.50
- **Term:** Month-to-month subscription (no auto-cancel)
- **Payment:** send_invoice, due next day
- **Early Adopter:** Tier 2 ($2,501–$5,000) + 60% off-tier discount, 3-month commitment, rates locked
- **Service Commencement:** No later than 3/15/2026
- **Stripe IDs:**
  - Customer: `cus_UAK0buRZfHg5gq`
  - Subscription: `sub_1TBzN6LsjTo3Ar3lS4PKCa88`
  - Price: `price_1TBzMpLsjTo3Ar3llJUfjVmU` ($3,891.50/mo custom)
  - Invoice #1: `in_1TBzfJLsjTo3Ar3ldM8Y2BYZ` (sent Mar 17, 2026, due Mar 18)
  - Voided invoice: `in_1TBzN6LsjTo3Ar3lAAuxutvv` (original, due same day — replaced)
- **Status:** Invoice sent to Jon — Mar 17, 2026
