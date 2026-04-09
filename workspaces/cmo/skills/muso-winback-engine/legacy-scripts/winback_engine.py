#!/usr/bin/env python3
"""
Muso Win-Back Pro - Daily Engine
Pulls unsent contacts, drafts emails, sends in timezone batches,
syncs GHL pipeline, labels Gmail, reports to Slack.
"""

import json
import os
import subprocess
import sys
import time
import argparse
from datetime import datetime, timezone, timedelta
from pathlib import Path

# === CONFIG ===
SHEET_ID = "1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs"
TAB = "High-Value Churns"
import os
GHL_KEY = os.environ.get("GHL_WINBACK_API_KEY", "")  # was hardcoded, moved to env var during 2026-04-09 rebuild
GHL_LOCATION = "fmK5Vl9sJv49WTYA0QyP"
GHL_PIPELINE = "AZa8jK5S7UyQ0fqfxzyB"
GHL_STAGES = {
    "churned": "819bd77b-9b34-4773-bdb3-4f532f925a9a",
    "emailed": "c01f6866-106a-4663-b177-93af8603a920",
    "replied": "73b66a22-98cb-47a5-b4fd-3b558394cc7b",
    "follow_up": "24f693ab-714e-4585-9245-100e50210eaa",
    "resubscribed": "e51bd206-edec-4bb5-b344-39b2d96cd39e",
    "lost": "6a357aa2-e62b-4e7e-92dc-d124530c44b2",
}
GMAIL_ACCOUNT = "a@muso.ai"
GMAIL_LABEL = "Win-Back Pro"
GMAIL_CC = "support@muso.ai"
SLACK_CHANNEL = "C0AHN078CSH"  # #clio_x_fede
LOG_DIR = Path.home() / ".openclaw/workspace/api-logs/gmail"
WORKSPACE = Path.home() / ".openclaw/workspace"

# Timezone buckets (send hour in PST)
TZ_BATCHES = {
    "EU": {"hour_pst": 6, "countries": [
        "Germany", "France", "Italy", "Netherlands", "Sweden", "Spain",
        "Belgium", "Austria", "Switzerland", "Denmark", "Norway", "Finland",
        "Poland", "Romania", "Czech Republic", "Hungary", "Greece", "Portugal",
        "Ireland", "United Kingdom", "Turkey",
    ]},
    "US_EAST": {"hour_pst": 9, "countries": ["United States", "Canada"]},
    "US_WEST": {"hour_pst": 10, "countries": []},  # overflow from US
    "APAC": {"hour_pst": 17, "countries": [
        "India", "Japan", "South Korea", "Australia", "New Zealand",
        "Philippines", "Singapore", "Indonesia", "Thailand",
    ]},
    "OTHER": {"hour_pst": 9, "countries": []},  # default
}

# Plan prices
PLAN_PRICES = {
    "Pro Monthly": 8.99,
    "Pro Annual": 7.50,
    "Pro Plus": 14.99,
}


def gog_cmd(args, timeout=15):
    """Run a gog CLI command and return output."""
    cmd = ["gog"] + args + ["--account", GMAIL_ACCOUNT]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return result.stdout, result.stderr, result.returncode


def ghl_api(method, endpoint, data=None):
    """Make a GHL API call."""
    import urllib.request
    url = f"https://services.leadconnectorhq.com{endpoint}"
    if "?" in url:
        url += f"&locationId={GHL_LOCATION}"
    else:
        url += f"?locationId={GHL_LOCATION}"

    headers = {
        "Authorization": f"Bearer {GHL_KEY}",
        "Version": "2021-07-28",
        "Accept": "application/json",
    }

    if data:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
    else:
        body = None

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        print(f"  GHL API error: {e}")
        return None


def read_sheet():
    """Read all rows from the High-Value Churns tab."""
    out, err, rc = gog_cmd([
        "sheets", "get", SHEET_ID,
        f"'{TAB}'!A1:Z1198", "-j"
    ], timeout=30)
    if rc != 0:
        print(f"Error reading sheet: {err}")
        return [], []

    data = json.loads(out)
    values = data.get("values", [])
    if not values:
        return [], []

    headers = values[0]
    rows = []
    for i, v in enumerate(values[1:], start=2):
        row = {}
        for j, h in enumerate(headers):
            row[h] = v[j] if j < len(v) else ""
        row["_sheet_row"] = i
        rows.append(row)

    return headers, rows


def get_unsent(rows, batch_size):
    """Get unsent contacts, prioritized."""
    unsent = [r for r in rows if not r.get("email_template", "").strip()]

    # Priority sort
    def priority(r):
        pop = int(r.get("popularity", "0") or "0")
        credits = int(r.get("credits_count", "0") or "0")
        ltv = float(r.get("Total LTV", "$0").replace("$", "") or "0")
        reason = r.get("cancel_reason", "")

        score = 0
        if pop >= 80:
            score += 1000
        if credits > 500:
            score += 500
        if reason == "payment_failed":
            score += 300
        score += ltv
        return -score  # negative for descending

    unsent.sort(key=priority)
    return unsent[:batch_size]


def assign_tz_batch(row):
    """Assign timezone batch based on country."""
    country = row.get("Country", "")
    for batch_name, config in TZ_BATCHES.items():
        if country in config["countries"]:
            return batch_name
    if country in ["United States", "Canada"]:
        return "US_EAST"
    return "OTHER"


def draft_email(row):
    """Generate personalized email for a contact."""
    first = row.get("first_name", "").strip()
    # Fix ALLCAPS names
    if first.isupper() and len(first) > 1:
        first = first.title()
    # Use just first name
    first = first.split()[0] if first else "there"

    credits = int(row.get("credits_count", "0") or "0")
    pop = int(row.get("popularity", "0") or "0")
    feedback = row.get("cancel_feedback", "")
    reason = row.get("cancel_reason", "")
    comment = row.get("cancel_comment", "").strip()
    language = row.get("Language", "English")
    strategy = row.get("winback_strategy", "")
    profile_name = row.get("profile_name", "")

    # Build email based on strategy and language
    if language == "French":
        return _draft_french(first, credits, pop, feedback, reason, comment)
    elif language == "Italian":
        return _draft_italian(first, credits, pop, feedback, reason, comment)
    elif language == "Dutch":
        return _draft_dutch(first, credits, pop, feedback, reason, comment)
    elif language == "Spanish":
        return _draft_spanish(first, credits, pop, feedback, reason, comment)
    elif language == "Portuguese":
        return _draft_portuguese(first, credits, pop, feedback, reason, comment)
    elif language == "German":
        return _draft_german(first, credits, pop, feedback, reason, comment)
    else:
        return _draft_english(first, credits, pop, feedback, reason, comment)


def _draft_english(name, credits, pop, feedback, reason, comment):
    """Draft English win-back email."""
    if reason == "payment_failed":
        subject = f"Your Muso profile needs attention"
        body = (f"Hey {name},\n\n"
                f"Just noticed your Muso account went inactive. Looks like it might be "
                f"a payment issue on our end. You've got {credits:,} credits on your profile "
                f"and they're not being tracked right now.\n\n"
                f"Want me to get your account sorted? Happy to help.\n\nAaron")
    elif feedback == "too_expensive":
        if comment and "apple" in comment.lower():
            subject = "About your feedback on Muso"
            body = (f"Hey {name},\n\n"
                    f"I read your note about Apple Music stats. We hear you. "
                    f"I'd like to offer you 3 free months while we work on expanding coverage. "
                    f"Your {credits:,} credits are worth keeping an eye on.\n\nAaron")
        else:
            subject = "Something for you"
            body = (f"Hey {name},\n\n"
                    f"I know the pricing was a factor. I'd like to offer you 3 free months "
                    f"to come back and try some of the new features we've built. "
                    f"Your {credits:,} credits have been updating since you left.\n\nAaron")
    elif feedback == "unused":
        subject = "Noticed something on your account"
        body = (f"Hey {name},\n\n"
                f"Saw you stepped away from Muso. If the platform wasn't clicking, "
                f"I'd love to know what was missing. We've added a lot recently and "
                f"your {credits:,} credits are still being tracked.\n\nAaron")
    elif feedback == "customer_service":
        subject = "About your experience with us"
        body = (f"Hey {name},\n\n"
                f"I saw your note about support being slow. That's on us and I'm sorry. "
                f"We've made changes since then. If you ever want to give us another shot, "
                f"reply directly to me. I'll handle it personally.\n\nAaron")
    elif pop >= 80:
        subject = f"Noticed something on your account"
        body = (f"Hey {name},\n\n"
                f"Noticed your Muso account went quiet. With {credits:,} credits and "
                f"your catalog still getting activity, wanted to check if everything's "
                f"good or if there's something we could do better.\n\nAaron")
    elif credits > 500:
        subject = f"Your {credits:,} credits are still updating"
        body = (f"Hey {name},\n\n"
                f"Just wanted you to know your catalog is still being tracked on Muso. "
                f"{credits:,} credits and counting. If you want to come back and take a look, "
                f"I'd be happy to set you up with some free time on the platform.\n\nAaron")
    else:
        subject = "A quick note from Muso"
        body = (f"Hey {name},\n\n"
                f"Saw you cancelled your Muso account. Just checking in to see if "
                f"there's anything we could have done better. Your profile with {credits:,} "
                f"credits is still there if you ever want to come back.\n\nAaron")

    return subject, body


def _draft_french(name, credits, pop, feedback, reason, comment):
    if reason == "payment_failed":
        return ("Ton profil Muso a besoin d'attention",
                f"Salut {name},\n\nJe viens de remarquer que ton compte Muso est devenu inactif. "
                f"On dirait un souci de paiement. Tu as {credits:,} credits sur ton profil "
                f"qui ne sont plus suivis. Je peux t'aider a remettre ca en ordre?\n\nAaron")
    return ("A propos de ton profil Muso",
            f"Salut {name},\n\nJ'ai vu que ton compte Muso n'est plus actif. "
            f"Tu as {credits:,} credits sur ton profil et on a ajoute pas mal de nouvelles "
            f"fonctionnalites depuis. Si tu veux jeter un oeil, je t'offre 3 mois gratuits.\n\nAaron")


def _draft_italian(name, credits, pop, feedback, reason, comment):
    if reason == "payment_failed":
        return ("Il tuo profilo Muso ha bisogno di attenzione",
                f"Ciao {name},\n\nHo notato che il tuo account Muso e diventato inattivo. "
                f"Sembra un problema di pagamento. Hai {credits:,} credits sul tuo profilo "
                f"che non vengono piu monitorati. Posso aiutarti a sistemare?\n\nAaron")
    return ("Una proposta per te",
            f"Ciao {name},\n\nHo visto che hai cancellato Muso. "
            f"Hai {credits:,} credits sul tuo profilo e vorrei offrirti 3 mesi gratis "
            f"per riprovare le nuove funzioni che abbiamo aggiunto. Nessun impegno.\n\nAaron")


def _draft_dutch(name, credits, pop, feedback, reason, comment):
    if reason == "payment_failed":
        return ("Je Muso profiel heeft aandacht nodig",
                f"Hey {name},\n\nIk zag dat je Muso account inactief is geworden. "
                f"Het lijkt op een betalingsprobleem. Je hebt {credits:,} credits op je profiel "
                f"die niet meer worden bijgehouden. Kan ik je helpen dit op te lossen?\n\nAaron")
    return ("Over je Muso profiel",
            f"Hey {name},\n\nZag dat je Muso account niet meer actief is. "
            f"Je hebt {credits:,} credits op je profiel staan. We hebben veel nieuwe tools "
            f"toegevoegd sinds je weg bent. Wil je 3 maanden gratis proberen?\n\nAaron")


def _draft_spanish(name, credits, pop, feedback, reason, comment):
    if reason == "payment_failed":
        return ("Tu perfil de Muso necesita atencion",
                f"Hola {name},\n\nNote que tu cuenta de Muso quedo inactiva. "
                f"Parece un problema de pago. Tienes {credits:,} creditos en tu perfil "
                f"que ya no se estan monitoreando. Puedo ayudarte a resolverlo?\n\nAaron")
    return ("Sobre tu perfil de Muso",
            f"Hola {name},\n\nVi que cancelaste tu cuenta de Muso. "
            f"Tienes {credits:,} creditos en tu perfil y hemos agregado muchas funciones nuevas. "
            f"Te ofrezco 3 meses gratis para que lo pruebes de nuevo.\n\nAaron")


def _draft_portuguese(name, credits, pop, feedback, reason, comment):
    if reason == "payment_failed":
        return ("Seu perfil Muso precisa de atencao",
                f"Oi {name},\n\nNotei que sua conta Muso ficou inativa. "
                f"Parece um problema de pagamento. Voce tem {credits:,} creditos no seu perfil "
                f"que nao estao mais sendo rastreados. Posso te ajudar a resolver?\n\nAaron")
    return ("Sobre seu perfil Muso",
            f"Oi {name},\n\nVi que voce cancelou sua conta Muso. "
            f"Voce tem {credits:,} creditos no seu perfil e adicionamos muitas funcionalidades novas. "
            f"Quero te oferecer 3 meses gratis para experimentar.\n\nAaron")


def _draft_german(name, credits, pop, feedback, reason, comment):
    if reason == "payment_failed":
        return ("Dein Muso Profil braucht Aufmerksamkeit",
                f"Hey {name},\n\nMir ist aufgefallen, dass dein Muso Account inaktiv geworden ist. "
                f"Sieht nach einem Zahlungsproblem aus. Du hast {credits:,} Credits auf deinem Profil, "
                f"die gerade nicht getrackt werden. Kann ich dir helfen?\n\nAaron")
    return ("Zu deinem Muso Profil",
            f"Hey {name},\n\nIch habe gesehen, dass du Muso gekuendigt hast. "
            f"Du hast {credits:,} Credits auf deinem Profil und wir haben viele neue Funktionen "
            f"hinzugefuegt. Ich biete dir 3 Monate kostenlos zum Testen an.\n\nAaron")


def qa_check(email, subject, body, row):
    """QA pass on a draft. Returns (pass, issues)."""
    issues = []

    # Length check
    if len(body) < 150:
        issues.append(f"Body too short ({len(body)} chars)")
    if len(body) > 400:
        issues.append(f"Body too long ({len(body)} chars)")

    # Em dash check
    if "\u2014" in body or "\u2013" in body:
        issues.append("Contains em/en dash")

    # Subject check
    if not subject:
        issues.append("Empty subject")
    if len(subject) > 60:
        issues.append(f"Subject too long ({len(subject)} chars)")

    # Email validity
    if "@" not in email or "." not in email.split("@")[-1]:
        issues.append("Invalid email format")

    # Personal email domain check (skip known bad domains)
    # These are all personal emails so this check is N/A for win-back

    return len(issues) == 0, issues


SIGNATURE_HTML = '<p>Aaron,<br>CEO &amp; Founder | <a href="https://www.muso.ai">www.muso.ai</a></p>'


def send_email(to, subject, body, dry_run=False):
    """Send email via gog gmail with CC to support and signature."""
    # Convert body to proper HTML paragraphs
    # Replace the trailing "Aaron" signoff with the full signature
    body_for_html = body.strip()
    if body_for_html.endswith("Aaron"):
        body_for_html = body_for_html[:-5].rstrip()

    paragraphs = body_for_html.split("\n\n")
    html_body = "".join(f"<p>{p.replace(chr(10), '<br>')}</p>" for p in paragraphs)
    html_body += SIGNATURE_HTML

    if dry_run:
        print(f"  [DRY RUN] Would send to {to} (CC: {GMAIL_CC})")
        return True, "dry_run"

    out, err, rc = gog_cmd([
        "gmail", "send",
        "--to", to,
        "--cc", GMAIL_CC,
        "--bcc", "aaron@muso.ai",
        "--subject", subject,
        "--body-html", html_body,
    ], timeout=15)

    if rc == 0 and "message_id" in out:
        msg_id = out.split("message_id\t")[1].split("\n")[0] if "message_id\t" in out else "unknown"
        return True, msg_id
    else:
        print(f"  Send failed: {err}")
        return False, err


def label_gmail(message_id):
    """Add Win-Back Pro label to sent email."""
    # Create label if needed, then apply
    gog_cmd(["gmail", "label", "create", GMAIL_LABEL], timeout=10)
    gog_cmd(["gmail", "label", "add", message_id, GMAIL_LABEL], timeout=10)


def create_ghl_contact(row):
    """Create or find contact in GHL Win-Back location."""
    email = row.get("email", "")
    first = row.get("first_name", "").title() if row.get("first_name", "").isupper() else row.get("first_name", "")
    last = row.get("last_name", "").title() if row.get("last_name", "").isupper() else row.get("last_name", "")

    # Search for existing contact
    result = ghl_api("GET", f"/contacts/lookup?email={email}")
    if result and result.get("contacts"):
        return result["contacts"][0]["id"]

    # Create new contact
    tags = ["win-back-pro"]
    credits = int(row.get("credits_count", "0") or "0")
    pop = int(row.get("popularity", "0") or "0")
    feedback = row.get("cancel_feedback", "")

    if credits > 500 or pop > 80:
        tags.append("high-value")
    if row.get("cancel_reason") == "payment_failed":
        tags.append("payment-recovery")
    if feedback and feedback != "not_provided":
        tags.append(f"churn-{feedback}")

    contact_data = {
        "locationId": GHL_LOCATION,
        "firstName": first,
        "lastName": last,
        "email": email,
        "tags": tags,
        "source": "Win-Back Campaign",
        "customFields": [
            {"key": "credits_count", "value": str(credits)},
            {"key": "popularity", "value": str(pop)},
            {"key": "cancel_reason", "value": feedback},
            {"key": "churn_date", "value": row.get("churn_date", "")},
        ]
    }

    result = ghl_api("POST", "/contacts/", contact_data)
    if result and result.get("contact"):
        return result["contact"]["id"]
    return None


def create_ghl_opportunity(contact_id, row, stage="churned"):
    """Create opportunity in the Win-Back pipeline."""
    ltv = row.get("Total LTV", "$0").replace("$", "")
    try:
        value = float(ltv)
    except:
        value = 0

    opp_data = {
        "locationId": GHL_LOCATION,
        "pipelineId": GHL_PIPELINE,
        "pipelineStageId": GHL_STAGES[stage],
        "contactId": contact_id,
        "name": f"Win-Back | {row.get('profile_name', row.get('first_name', 'Unknown'))}",
        "status": "open",
        "monetaryValue": value,
    }

    return ghl_api("POST", "/opportunities/", opp_data)


def update_sheet_row(row_num, date_str, subject, body, stage="Emailed"):
    """Update sheet row with full tracking: email_template, Next Up cleared, subject, body, pipeline stage."""
    # S = email_template (mark as emailed with date)
    # Y = Next Up (clear it)
    # Z = Email Subject Sent
    # AA = Email Body Sent
    # AB = Pipeline Stage
    gog_cmd([
        "sheets", "update", SHEET_ID,
        f"'{TAB}'!S{row_num}",
        "--values-json", json.dumps([[f"Emailed {date_str}"]]),
    ], timeout=10)
    gog_cmd([
        "sheets", "update", SHEET_ID,
        f"'{TAB}'!Y{row_num}",
        "--values-json", json.dumps([["", subject, body[:500], stage]]),
    ], timeout=10)


def mark_next_up(row_nums, batch_label):
    """Mark rows as Next Up for tomorrow's batch."""
    for rn in row_nums:
        gog_cmd([
            "sheets", "update", SHEET_ID,
            f"'{TAB}'!Y{rn}",
            "--values-json", json.dumps([[batch_label]]),
        ], timeout=10)


def update_sheet_reply(row_num, reply_date, reply_content):
    """Update sheet row with reply data."""
    # AC = Reply Date, AD = Reply Content
    gog_cmd([
        "sheets", "update", SHEET_ID,
        f"'{TAB}'!AC{row_num}",
        "--values-json", json.dumps([[reply_date, reply_content[:500]]]),
    ], timeout=10)
    # Also update Pipeline Stage
    gog_cmd([
        "sheets", "update", SHEET_ID,
        f"'{TAB}'!AB{row_num}",
        "--values-json", json.dumps([["Replied"]]),
    ], timeout=10)


def log_send(to, subject, message_id, status="sent"):
    """Log email send to api-logs."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.now().strftime("%Y-%m-%d")
    log_file = LOG_DIR / f"{today}.jsonl"

    entry = {
        "action": "winback_send",
        "to": to,
        "subject": subject,
        "message_id": message_id,
        "status": status,
        "account": GMAIL_ACCOUNT,
        "campaign": "win-back-pro",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    with open(log_file, "a") as f:
        f.write(json.dumps(entry) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Muso Win-Back Daily Engine")
    parser.add_argument("--batch-size", type=int, default=120)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    print("Step 1: Reading sheet...")
    headers, rows = read_sheet()
    if not rows:
        print("No data found in sheet!")
        return

    print(f"  Total rows: {len(rows)}")

    print("\nStep 2: Selecting unsent contacts...")
    batch = get_unsent(rows, args.batch_size)
    print(f"  Selected: {len(batch)} contacts")

    if not batch:
        print("No unsent contacts remaining!")
        return

    print("\nStep 3: Assigning timezone batches...")
    tz_groups = {}
    for row in batch:
        tz = assign_tz_batch(row)
        tz_groups.setdefault(tz, []).append(row)

    for tz, group in tz_groups.items():
        print(f"  {tz}: {len(group)} contacts (send at {TZ_BATCHES.get(tz, TZ_BATCHES['OTHER'])['hour_pst']}:00 PST)")

    # Load QA engine
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from qa_checklist import run_full_qa, qa_batch

    # Get already-sent emails for dupe check
    sent_emails = set()
    for row in rows:
        if row.get("email_template", "").strip():
            sent_emails.add(row["email"].lower())

    print("\nStep 4: Drafting emails + Multi-Pass QA...")
    draft_list = []
    for row in batch:
        email = row["email"]
        subject, body = draft_email(row)
        draft_list.append({
            "email": email,
            "subject": subject,
            "body": body,
            "row": row,
        })

    approved, rejected = qa_batch(draft_list, sent_emails)

    print(f"  QA approved: {len(approved)}")
    print(f"  QA rejected: {len(rejected)}")
    for rej in rejected:
        print(f"    ❌ {rej['email']}: {rej['qa_result'].summary()}")

    print("\nStep 5: Sending emails (with CC to support)...")
    sent_count = 0
    failed_count = 0
    today = datetime.now().strftime("%Y-%m-%d")

    for i, draft in enumerate(approved):
        row = draft["row"]
        email = draft["email"]
        subject = draft["subject"]
        body = draft["body"]

        print(f"  [{i+1}/{len(approved)}] {email}...")

        # Send
        success, msg_id = send_email(email, subject, body, dry_run=args.dry_run)

        if success:
            sent_count += 1

            if not args.dry_run:
                # Log
                log_send(email, subject, msg_id)

                # Label in Gmail
                label_gmail(msg_id)

                # Update sheet with full tracking
                update_sheet_row(row["_sheet_row"], today, subject, body, "Emailed")

                # GHL: create contact + opportunity
                contact_id = create_ghl_contact(row)
                if contact_id:
                    create_ghl_opportunity(contact_id, row, "emailed")
                    print(f"    GHL synced: {contact_id}")

                # Rate limit: ~2 per second
                time.sleep(0.5)
        else:
            failed_count += 1

    print(f"\n=== SUMMARY ===")
    print(f"Sent: {sent_count}")
    print(f"Failed: {failed_count}")
    print(f"QA rejected: {len(rejected)}")

    # Return summary for Slack reporting
    summary = {
        "date": today,
        "sent": sent_count,
        "failed": failed_count,
        "qa_rejected": len(qa_fails),
        "total_remaining": len([r for r in rows if not r.get("email_template", "").strip()]) - sent_count,
        "dry_run": args.dry_run,
    }

    with open("/tmp/winback_summary.json", "w") as f:
        json.dump(summary, f)

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
