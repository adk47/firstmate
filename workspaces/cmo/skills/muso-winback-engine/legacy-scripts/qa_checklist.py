#!/usr/bin/env python3
"""
Win-Back Pro - Multi-Pass QA Engine
Runs every draft through a rigorous checklist before it can be sent.
Three passes: structural, content, cross-reference. Must pass all three.
"""

import re
import json


class QAResult:
    def __init__(self):
        self.passes = []
        self.failures = []
        self.warnings = []

    def passed(self):
        return len(self.failures) == 0

    def add_pass(self, check, detail=""):
        self.passes.append({"check": check, "detail": detail})

    def add_fail(self, check, detail):
        self.failures.append({"check": check, "detail": detail})

    def add_warn(self, check, detail):
        self.warnings.append({"check": check, "detail": detail})

    def summary(self):
        status = "PASS" if self.passed() else "FAIL"
        lines = [f"QA Result: {status}"]
        lines.append(f"  Passes: {len(self.passes)}")
        if self.warnings:
            lines.append(f"  Warnings: {len(self.warnings)}")
            for w in self.warnings:
                lines.append(f"    ⚠️ {w['check']}: {w['detail']}")
        if self.failures:
            lines.append(f"  Failures: {len(self.failures)}")
            for f in self.failures:
                lines.append(f"    ❌ {f['check']}: {f['detail']}")
        return "\n".join(lines)


def run_full_qa(email, subject, body, row, sent_emails=None):
    """
    Three-pass QA. Returns QAResult.
    sent_emails: set of already-sent email addresses (for dupe check)
    """
    result = QAResult()

    # === PASS 1: STRUCTURAL ===
    _pass_structural(email, subject, body, row, result)

    # === PASS 2: CONTENT ===
    _pass_content(email, subject, body, row, result)

    # === PASS 3: CROSS-REFERENCE ===
    _pass_crossref(email, subject, body, row, sent_emails or set(), result)

    return result


def _pass_structural(email, subject, body, row, result):
    """Pass 1: Basic structural checks."""

    # 1.1 Email format
    if not email or "@" not in email:
        result.add_fail("email_format", f"Invalid email: {email}")
    elif "." not in email.split("@")[-1]:
        result.add_fail("email_format", f"Invalid domain: {email}")
    else:
        result.add_pass("email_format")

    # 1.2 Email not a noreply/bounce address
    bad_prefixes = ["noreply", "no-reply", "bounce", "mailer-daemon", "postmaster"]
    local = email.split("@")[0].lower() if email else ""
    if any(local.startswith(p) for p in bad_prefixes):
        result.add_fail("email_noreply", f"Noreply address: {email}")
    else:
        result.add_pass("email_noreply")

    # 1.3 Subject exists and length
    if not subject or not subject.strip():
        result.add_fail("subject_empty", "Subject is empty")
    elif len(subject) > 80:
        result.add_fail("subject_long", f"Subject too long: {len(subject)} chars (max 80)")
    elif len(subject) < 5:
        result.add_fail("subject_short", f"Subject too short: {len(subject)} chars")
    else:
        result.add_pass("subject_length")

    # 1.4 Body length (150-400 chars, allowing slight overflow for non-English)
    body_len = len(body)
    if body_len < 100:
        result.add_fail("body_short", f"Body too short: {body_len} chars (min 100)")
    elif body_len > 500:
        result.add_fail("body_long", f"Body too long: {body_len} chars (max 500)")
    elif body_len < 150:
        result.add_warn("body_short_warn", f"Body is short: {body_len} chars (target 150+)")
    elif body_len > 400:
        result.add_warn("body_long_warn", f"Body is long: {body_len} chars (target <400)")
    else:
        result.add_pass("body_length")

    # 1.5 Body ends with Aaron
    if not body.strip().endswith("Aaron"):
        result.add_fail("signoff", "Body doesn't end with 'Aaron'")
    else:
        result.add_pass("signoff")


def _pass_content(email, subject, body, row, result):
    """Pass 2: Content quality checks."""

    # 2.1 No em dashes
    if "\u2014" in body or "\u2013" in body or "\u2014" in subject or "\u2013" in subject:
        result.add_fail("em_dash", "Contains em dash or en dash")
    else:
        result.add_pass("em_dash")

    # 2.2 No marketing buzzwords
    buzzwords = [
        "exclusive offer", "limited time", "act now", "don't miss",
        "special discount", "hurry", "last chance", "click here",
        "unsubscribe", "opt out", "terms and conditions",
        "we'd love to", "we'd be happy to", "I'd be happy to help",
        "great question", "absolutely", "leverage", "synergy",
    ]
    body_lower = body.lower()
    found = [w for w in buzzwords if w in body_lower]
    if found:
        result.add_fail("buzzwords", f"Marketing buzzwords found: {', '.join(found)}")
    else:
        result.add_pass("buzzwords")

    # 2.3 Name check - first word after greeting should be a name
    first_name = row.get("first_name", "").strip()
    if first_name:
        # Check name is in the body
        if first_name.lower() not in body.lower() and first_name.title() not in body:
            result.add_warn("name_missing", f"First name '{first_name}' not found in body")
        else:
            result.add_pass("name_in_body")

        # Check for ALLCAPS name in body
        if first_name.isupper() and len(first_name) > 1 and first_name in body:
            result.add_fail("name_allcaps", f"Name is ALLCAPS in body: {first_name}")
        else:
            result.add_pass("name_format")

        # Check for full name (first + last) in greeting — should be first only
        last_name = row.get("last_name", "").strip()
        if last_name and f"{first_name} {last_name}" in body.split("\n")[0]:
            result.add_fail("full_name_greeting", f"Full name in greeting: use first name only")
        else:
            result.add_pass("greeting_format")

    # 2.4 Language consistency
    language = row.get("Language", "English")
    if language == "French":
        if body.startswith("Hey ") or body.startswith("Hi "):
            result.add_fail("language_mismatch", "French email starts with English greeting")
        else:
            result.add_pass("language_match")
    elif language == "Italian":
        if body.startswith("Hey ") or body.startswith("Hi "):
            result.add_fail("language_mismatch", "Italian email starts with English greeting")
        else:
            result.add_pass("language_match")
    elif language == "Dutch":
        if not any(body.startswith(g) for g in ["Hey ", "Hoi ", "Hallo "]):
            result.add_warn("language_check", "Dutch email - verify greeting")
        else:
            result.add_pass("language_match")
    elif language == "Spanish":
        if body.startswith("Hey ") or body.startswith("Hi "):
            result.add_fail("language_mismatch", "Spanish email starts with English greeting")
        else:
            result.add_pass("language_match")
    elif language == "German":
        if not any(body.startswith(g) for g in ["Hey ", "Hallo ", "Hi "]):
            result.add_warn("language_check", "German email - verify greeting")
        else:
            result.add_pass("language_match")
    else:
        result.add_pass("language_match")

    # 2.5 Credits count accuracy
    credits = row.get("credits_count", "0")
    if credits and int(credits or 0) > 0:
        credits_str = f"{int(credits):,}"
        if credits_str not in body and str(credits) not in body:
            result.add_warn("credits_missing", f"Credits ({credits_str}) not mentioned in body")
        else:
            result.add_pass("credits_accuracy")

    # 2.6 No placeholder text
    placeholders = ["{", "}", "{{", "}}", "[NAME]", "[CREDITS]", "FIRSTNAME", "TODO", "TBD"]
    found_ph = [p for p in placeholders if p in body]
    if found_ph:
        result.add_fail("placeholders", f"Placeholder text found: {', '.join(found_ph)}")
    else:
        result.add_pass("placeholders")

    # 2.7 Subject is not a greeting or intro
    subject_lower = subject.lower().strip()
    greeting_subjects = ["hey", "hi", "hello", "yo", "sup", "salut", "ciao", "hallo", "hola"]
    if subject_lower in greeting_subjects:
        result.add_fail("subject_greeting", f"Subject is just a greeting: '{subject}'")
    else:
        result.add_pass("subject_not_greeting")

    # 2.8 Subject doesn't start with "Re:" (unless it's a follow-up)
    if subject.lower().startswith("re:") and "follow" not in row.get("Pipeline Stage", "").lower():
        result.add_warn("subject_re", "Subject starts with Re: but this isn't a follow-up")
    else:
        result.add_pass("subject_format")


def _pass_crossref(email, subject, body, row, sent_emails, result):
    """Pass 3: Cross-reference checks."""

    # 3.1 Duplicate send check
    if email.lower() in sent_emails:
        result.add_fail("duplicate", f"Already sent to {email}")
    else:
        result.add_pass("not_duplicate")

    # 3.2 Churn date sanity - should be within last 6 months
    churn_date = row.get("churn_date", "")
    if churn_date:
        try:
            from datetime import datetime, timedelta
            cd = datetime.strptime(churn_date[:10], "%Y-%m-%d")
            now = datetime.now()
            days_ago = (now - cd).days
            if days_ago > 365:
                result.add_warn("stale_churn", f"Churned {days_ago} days ago (>1 year)")
            elif days_ago < 0:
                result.add_fail("future_churn", f"Churn date is in the future: {churn_date}")
            else:
                result.add_pass("churn_date_valid")
        except:
            result.add_warn("churn_date_parse", f"Could not parse churn date: {churn_date}")

    # 3.3 Strategy matches email content
    strategy = row.get("winback_strategy", "").lower()
    if "payment" in strategy and "payment" not in body.lower() and "inactive" not in body.lower():
        result.add_warn("strategy_mismatch", "Payment recovery strategy but email doesn't mention payment/inactive")
    elif "price" in strategy and "free" not in body.lower() and "offer" not in body.lower() and "cost" not in body.lower():
        result.add_warn("strategy_mismatch", "Price-sensitive strategy but no offer mentioned")
    else:
        result.add_pass("strategy_alignment")

    # 3.4 Email domain is deliverable (basic check)
    domain = email.split("@")[-1].lower() if "@" in email else ""
    disposable_domains = [
        "mailinator.com", "guerrillamail.com", "tempmail.com", "throwaway.email",
        "yopmail.com", "sharklasers.com", "grr.la", "10minutemail.com",
    ]
    if domain in disposable_domains:
        result.add_fail("disposable_email", f"Disposable email domain: {domain}")
    else:
        result.add_pass("email_domain")


def qa_batch(drafts, sent_emails=None):
    """Run QA on a full batch. Returns (approved, rejected) lists."""
    approved = []
    rejected = []
    sent = sent_emails or set()

    for draft in drafts:
        result = run_full_qa(
            email=draft["email"],
            subject=draft["subject"],
            body=draft["body"],
            row=draft["row"],
            sent_emails=sent,
        )

        draft["qa_result"] = result

        if result.passed():
            approved.append(draft)
            sent.add(draft["email"].lower())  # Track within batch too
        else:
            rejected.append(draft)

    return approved, rejected


if __name__ == "__main__":
    # Test with a sample
    test_row = {
        "email": "test@example.com",
        "first_name": "Sam",
        "last_name": "Smith",
        "credits_count": "3094",
        "popularity": "86",
        "cancel_feedback": "too_expensive",
        "cancel_reason": "voluntary",
        "Language": "English",
        "churn_date": "2026-01-15",
        "winback_strategy": "Price-sensitive power user",
    }

    result = run_full_qa(
        email="test@example.com",
        subject="Something for you",
        body="Hey Sam,\n\nI know the pricing was a factor. I'd like to offer you 3 free months to come back and try some of the new features we've built. Your 3,094 credits have been updating since you left.\n\nAaron",
        row=test_row,
    )

    print(result.summary())
