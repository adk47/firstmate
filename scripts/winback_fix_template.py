#!/usr/bin/env python3
"""Emit the muso-messaging drop-in for the `wb_fix_1` send-gateway template.

The campaign copy lives in exactly ONE place - `policies/winback-fix.json` - and this script is
how the OTHER repo gets its bytes without a second hand-maintained copy of the sentences. It
writes the `native.json` entry plus the body files for muso-messaging (`templates/native.json`
and `templates/native/wb_fix_1/`), which is the whole deliverable on that side:

    ./scripts/winback_fix_template.py --out "$PAPERCLIP_RUN_SCRATCH_DIR/wb_fix_1"
    ./scripts/winback_fix_template.py            # print the entry + bodies, write nothing

The template ships `enabled: false`. Sending is gated twice over and this script is not a gate:
`template.enabled` + `fable_go_ref` in the policy is the Fable GO on the six rendered variants,
`--live` needs `/etc/hydra/winback-fix.live`, and the sender seat owns the fleet daily cap.

Why the placeholders look the way they do: send-gateway renders the Django-like subset in
`services/send-gateway/src/render.js` with the context `{ event, person, organization, links }`.
Bare names resolve against `person.*`, so `{{ first_name }}` is the recipient; every campaign
value is `event.*` and is supplied by the hand-off manifest. `tests/test_churn_template.py`
renders this skeleton with the lane's own renderer and asserts it produces the same sentence as
`scripts/churn/render.py` - one copy source, two renderers, equality pinned in CI.
"""

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from churn import cli, guards  # noqa: E402

FOOTER = (
    "You're getting this because you have a Muso account. "
    "Unsubscribe: {% unsubscribe_url %} \u00b7 Email preferences: {% manage_preferences_url %}\n"
    "Muso.AI \u00b7 2200 Post Oak Blvd, Suite 1000 \u00b7 Houston, TX 77056"
)

# Policy body placeholders -> the gateway's variable names. `first_name` is a person field; the
# rest ride on the event because they are per-send facts, not recipient profile data.
VAR_MAP = {
    "{first_name}": "{{ first_name }}",
    "{cause_noun}": "{{ event.cause_noun }}",
    "{fix_line}": "{{ event.fix_line }}",
    "{plan_noun}": "{{ event.plan_noun }}",
    "{pro_ended_date}": "{{ event.pro_ended_date }}",
    "{offer_line}": "{{ event.offer_line }}",
}


def _convert(line, policy):
    out = line
    for source, target in VAR_MAP.items():
        out = out.replace(source, target)
    if "{" in out.replace("{{", "").replace("}}", ""):
        raise SystemExit(f"unconverted placeholder in the template body: {line!r}")
    return out


def body_text(policy):
    """The whole email body: the policy's sentences, then the marketing footer."""
    lines = [_convert(line, policy) for line in policy["template"]["body"]]
    return "\n\n".join(lines) + "\n\n" + FOOTER + "\n"


def body_html(policy):
    """A minimal HTML wrapper. The text body is the source of truth; this is paragraphs."""
    import html as _html

    paragraphs = "".join(
        f"  <p>{_html.escape(_convert(line, policy)).replace('{{ ', '<code>{{ ').replace(' }}', ' }}</code>')}</p>\n"
        for line in policy["template"]["body"]
    )
    return (
        "<!doctype html>\n<html>\n<body style=\"font-family:Helvetica,Arial,sans-serif;font-size:16px\">\n"
        f"{paragraphs}"
        "  <p style=\"color:#888;font-size:12px\">You're getting this because you have a Muso account. "
        "<a href=\"{% unsubscribe_url %}\">Unsubscribe</a> &middot; "
        "<a href=\"{% manage_preferences_url %}\">Email preferences</a><br>"
        "Muso.AI &middot; 2200 Post Oak Blvd, Suite 1000 &middot; Houston, TX 77056</p>\n"
        "</body>\n</html>\n"
    )


def native_entry(policy):
    """The `templates/native.json` entry, same shape as every other native template."""
    tpl = policy["template"]
    key = tpl["key"]
    return {
        "class": "marketing",
        "subdomain": "news",
        "enabled": False,
        "from_local": "aaron",
        "from_name": "Aaron | Muso.AI",
        "reply_to": "support@muso.ai",
        "subject": tpl["subject"],
        "preview_text": "",
        "smart_sending": False,
        "utm": False,
        "utm_custom": None,
        "html": f"native/{key}/body.html",
        "text": f"native/{key}/body.txt",
        "native": {
            "trigger_metric": "wb_fix_1",
            "caller": (
                "scripts/winback_fix_send.py (hydra) hands one batch manifest to the sender seat "
                "verify-sla-driver-fable-d2; props first_name, cause_noun, fix_line, plan_noun, "
                "pro_ended_date, offer_line"
            ),
            "campaign": policy["campaign"],
            "rule": "R2: only sent for a user whose fix READ BACK as Seen (scripts/fix_readback.py)",
            "requested_by": tpl.get("requested_by") or policy.get("source_ruling"),
        },
    }


def emit(policy, out_dir):
    key = policy["template"]["key"]
    root = pathlib.Path(out_dir)
    (root / "native" / key).mkdir(parents=True, exist_ok=True)
    entry = native_entry(policy)
    (root / "native" / key / "body.txt").write_text(body_text(policy))
    (root / "native" / key / "body.html").write_text(body_html(policy))
    (root / "wb_fix_1.native-entry.json").write_text(json.dumps({key: entry}, indent=2) + "\n")
    return entry


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    cli.add_common(ap)
    ap.add_argument("--out", help="write the drop-in here (default: print it)")
    args = ap.parse_args(argv)
    policy = cli.load_policy(args.policy)

    text = body_text(policy)
    # The template that ships is the same copy, so it passes the same guard. A body that only
    # passes because nobody checked it is how these users were burned the first time.
    probe = {"subject": policy["template"]["subject"], "body": text, "variant": "template"}
    verdict = guards.check_rendered(_Rendered(probe), policy)
    if not verdict.ok:
        cli.log(f"guard refused the template body: {verdict.reason()}")
        return 2

    entry = emit(policy, args.out) if args.out else native_entry(policy)
    doc = {"campaign": policy["campaign"], "template": entry, "text": text,
           "enabled": entry["enabled"], "fable_go_ref": policy["template"].get("fable_go_ref")}
    if args.out:
        cli.log(f"wrote the {policy['template']['key']} drop-in under {args.out}")
        doc["out"] = args.out
    cli.emit(doc)
    return 0


class _Rendered:
    """Minimal duck type so the guard sees the template exactly as it sees a message."""

    def __init__(self, fields):
        self.subject = fields["subject"]
        self.body = fields["body"]
        self.variant = fields.get("variant")
        self.coupon = None


if __name__ == "__main__":
    sys.exit(main())
