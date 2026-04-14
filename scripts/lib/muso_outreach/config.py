"""Constants mirrored from
workspaces/cmo/skills/muso-outreach-engine/references/config.md.

Keep this file in sync with that doc — the pre-commit hook does not
enforce the mirroring; we rely on code review.
"""
from __future__ import annotations

# Google Sheets
CONTACTS_SHEET_ID = "1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I"
CONTACTS_TAB = "contacts_intelligence"
LOGBOOK_SHEET_ID = "1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0"
# The real tab name in the sheet is "Logobook" (sic — typo in the sheet,
# not a bug here). Changing the tab name would break Fede's existing
# filter views and formulas, so we match the sheet as-is.
LOGBOOK_TAB = "Logobook"

# Gmail
OUTREACH_LABEL = "B2B - Ads"
AUTO_FU_APPROVED_LABEL = "B2B - Ads/auto-fu-approved"
OVERRIDE_APPROVED_LABEL = "B2B - Ads/override-approved"
META_LABEL_PREFIX = "muso-meta/"

# Production-safe outreach accounts (only a@muso.ai for now, per
# warming schedule in config.md).
OUTREACH_ALLOWED_SENDERS = frozenset({"a@muso.ai"})
# All muso.ai mailboxes we scan for crosscheck purposes.
MUSO_ACCOUNTS = (
    "a@muso.ai",
    "ak@muso.ai",
    "aaron.k@muso.ai",
    "f@muso.ai",
)

# Slack
SALES_ALERTS_CHANNEL = "C0ARQ021M40"  # #sales-alerts
DEVOPS_CHANNEL = "C0ADV2W76G4"  # #clio_devops

# GHL
GHL_LOCATION_ID = "S5w31kRRgsBjjiVATWlP"
GHL_PIPELINE_ID = "GeSt85TueSvJ0SNFZXfQ"

# Policy
MAX_FOLLOWUPS_PER_CONTACT = 3
CONTACT_REPLY_LOOKBACK_DAYS_NEW = 60
