---
name: "milestone-badge-purchase"
description: "Buy a milestone badge or plaque; verify profile and streams, then route pre-order corrections or existing-order issues."
---

# Milestone Badge Purchase

1. Resolve the requested profile with `profile_lookup` using the customer's supplied profile URL or exact profile name; when several matches exist, select only an exact verified match or ask for the profile link, and finish with one profile ID.
2. Read `profile_analytics_status` for that profile before discussing the printed milestone; finish with the current measured lifetime-stream total or a closed-failure result.
3. Distinguish a pre-order purchase from an existing plaque/poster order. Use the order-fulfillment path only when the customer supplies an order reference or asks about an order already placed; finish with the request classified as pre-order or existing-order.
4. For a pre-order request where the customer disputes the measured total, file one `analytics-followup` containing the profile ID, observed total, customer-stated total, and that correction is needed before purchase; quote only the returned SLA and finish with a confirmed handoff.
5. For a pre-order customization question about printed milestone wording or number formatting, file one `support-general` request containing the profile ID, observed stream total, requested print text, standard milestone label, and that the customer wants confirmation before ordering; quote only the returned SLA and finish with a confirmed handoff.
6. When the customer follows up on that unresolved customization request, call `create_ticket` again with the same `support-general` action type and the new check-in context so it appends to the existing request; if the result says `updated_existing`, acknowledge the update without quoting the SLA again, and finish with the existing request advanced rather than duplicated.
7. Do not claim the badge can be printed with a customer-selected number or that the analytics total was corrected until a verified result says so; finish with wording limited to the observed state and confirmed next step.
