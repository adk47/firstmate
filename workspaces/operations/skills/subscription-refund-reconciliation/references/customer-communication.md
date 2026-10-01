# Customer communication bar

Part of the `subscription-refund-reconciliation` skill. The safety rules in its `SKILL.md` bind this file and win over anything here.

Addition to SKILL.md Procedure step 9 (customer-facing restriction, distinct from the engineering symptom report step 9 also requires).

Say that no payment or subscription change has been made only when no write succeeded. If any write in the resolution succeeded, do not tell the customer nothing changed — report the specific confirmed change instead.
