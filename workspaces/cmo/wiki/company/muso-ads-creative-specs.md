---
title: Muso Ads — Creative Specs & Asset Requirements
description: Image sizes, copy limits, and asset requirements for all Muso Ads placements
type: reference
status: active
source: "Muso Ads × Slate Digital - Creative Specs & Asset Requirements" (Google Doc)
source-link: https://docs.google.com/document/d/1dU7LcfF2In6c5Rb5i1ZH957XQB_xcb9WZBRBa9zt0Xs/edit
last-verified: 2026-04-15
updated: 2026-04-15
related: [[company/muso-ads]]
---

# Muso Ads — Creative Specs & Asset Requirements

## Placement Types

| Placement | Description | Targeting |
|-----------|-------------|-----------|
| AMP (Standard) | Broad placement in the AMP marketplace | None — shown to all users |
| AMP For You | Personalized slot in AMP | Targeted (role, genre, streams, geography, etc.) |
| Feed | Native ad card in the news feed | Targeted |

---

## Image Specs

### AMP (Standard + For You)
- **Media**: 1280 × 720 px (16:9 ratio), up to 5 images — first image is hero
- **Logo**: Square format (PNG or SVG), light + dark versions if available

### Feed Ad
- **Media**: 1280 × 720 px (16:9) OR 1280 × 1280 px (1:1)
- **Logo**: Square format (PNG or SVG)

### General
- High-resolution, no watermarks
- Accepted formats: JPEG, PNG, GIF, WEBP (API); PNG/SVG preferred for logos
- Logos: provide light + dark versions when available

---

## Copy Limits

### AMP (Standard + For You)

| Field | Max Length |
|-------|-----------|
| Company Name | 30 characters |
| Offer Description | 120 characters |
| Badge | 12–16 characters |
| Additional Text (detail view) | 500 characters |
| Promo Code | Short alphanumeric |
| CTA Text | e.g. "Learn More", "Get Offer", "Shop Now" |
| CTA URL | Full URL (UTM-tagged recommended) |

### Feed Ad

| Field | Max Length |
|-------|-----------|
| Body | 112 characters |
| Headline | 20 characters |
| Display URL | 24 characters |
| CTA Button | 10 characters |
| Media | 1280×720 (16:9) or 1280×1280 (1:1) |

---

## Asset Delivery Checklist

- [ ] Logo (square, PNG or SVG, light + dark)
- [ ] AMP images (1280×720, up to 5)
- [ ] AMP copy (company name, offer description, badge, additional text)
- [ ] Promo code (if applicable, tested and active)
- [ ] Feed ad copy (body, headline, display URL, CTA) + image
- [ ] Video ad (if applicable): 16:9, ≤30s, ≤30 MB, MP4/MOV/WEBM
- [ ] All CTA destination URLs (UTM-tagged)

---

## Video Specs

> Added 2026-04-15 from #growth-team discussion (Fede, Serhii, Artem).

### Resolution & Aspect Ratio (V1 — confirmed by Fede 2026-04-15)
- **Aspect ratio**: 16:9 (locked for V1 — all placements, image + video)
- **Resolution**: 1280 × 720 px (matches current image ad dimensions)
  - 1920 × 1080 is acceptable as source but will be downscaled to 1280 × 720 for delivery
  - Note: Fede flagged 16:9 feels narrow on mobile Feed — revisit ratio for V2 (e.g. 4:5 or 1:1 for Feed)
- **Max duration**: 30 seconds
- **Target file size**: ≤ 30 MB (compressed)

### Encoding & Compression
- Server-side transcoding with ffmpeg before serving to clients
- Preview playback (not full-screen) — smaller resolutions acceptable in-app
- Accepted source formats: MP4, MOV, WEBM
- Delivery codec: H.264 (MP4 container) for widest compatibility

### Key Decisions
- 16:9 locked to match existing image ad aspect ratio (consistency across placements)
- 30-second cap prevents heavy files and keeps load times fast
- Client uploads full-res source → platform compresses/converts on ingest

---

## General Guidelines

- All images high-res, no watermarks
- UTM parameters on all destination URLs strongly recommended
- Promo codes tested and active before launch
- All copy subject to Muso editorial review before going live
- Assets delivered at least 2 business days before campaign start

---

## Links

- Onboarding form: https://musoai.app.n8n.cloud/webhook/muso-ads-form
- Targeting/pricing: access.muso.ai/pricing
- Contact: fede@muso.ai

---

## Source Docs on Drive

- [Muso Ads × Slate Digital - Creative Specs](https://docs.google.com/document/d/1dU7LcfF2In6c5Rb5i1ZH957XQB_xcb9WZBRBa9zt0Xs/edit)
- [Muso Ads × IK Multimedia - Creative Specs](https://docs.google.com/document/d/14AsIKW1g0FSLENSzN660c1bqUSuFza2fUSBpWI2EjMY/edit)
- [Muso Ads x Slate Digital v1](https://docs.google.com/document/d/1s79GTSKydELP4wsRaWgWgRvbAgSifsdlsj4kDzPIKuE/edit)
- [Muso Ads x Slate Digital v2](https://docs.google.com/document/d/1pnJREMtBhY1angjXfK4KzhfQu_yFooWwtAJDJfOXz78/edit)
