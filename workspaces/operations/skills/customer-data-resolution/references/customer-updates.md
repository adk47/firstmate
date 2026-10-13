# Customer update cases

Part of the `customer-data-resolution` skill. The safety rules in its `SKILL.md` bind every case here and win over anything in this file.

Case-specific additions to SKILL.md Procedure step 7.

- For a legal/stage-name consolidation, read both profile claims and independently resolve every linked group/artist ID and name; keep groups separate, verify existing claim evidence before requesting resubmission, and explain that a group claim grants management but no public member link.
- For a mobile freeze, update/create one handoff after restart/reopen and update checks, ask once for OS/app versions, affected controls, and a screen recording, and never claim recovery without proof.
- For an expired invoice PDF, resolve the verified customer to the billing customer, retrieve the exact invoice by number, confirm status/amount/currency, fetch the current `invoice_pdf`, and require HTTP 200 plus a `%PDF-` signature before sharing that fresh link; never reuse the expired URL or expose unrelated invoices.
- When the stated reason is that releases are no longer available on streaming, first ask whether the credits are actually misattributed; preserve accurate historical credits, and run the owned credit-removal workflow only for exact misattributed credits after ownership is verified.
