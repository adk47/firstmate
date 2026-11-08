"""A GO the policy cites must exist as evidence, in its own file, on the copy it approves.

`docs/support/copy-gos/<slug>.md` is an owned text contract: one human-readable record per
granted approval, with fixed `##` sections carrying the approval ref, the approved text
verbatim, the ruling verbatim, its date, the seat that granted it, its conditions and where the
original archive lives. The policy's `fable_go_ref` is only a CLAIM to one of those files, so a
ref cannot be self-granted by editing the policy alone: this module parses the policy and every
evidence file into a model and asserts they agree.

The failure it prevents is real, not hypothetical - an earlier round of this change set
`offers.regional_suffix.fable_go_ref` to a ref no document recorded, which would have shipped a
price sentence on the strength of an approval nobody gave.
"""

import datetime
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY = ROOT / "policies" / "winback-fix.json"
GOS = ROOT / "docs" / "support" / "copy-gos"

REQUIRED_SECTIONS = ("Approval ref", "Approved text", "Ruling (verbatim)", "Date",
                     "Approver seat", "Conditions", "Archive")
#: A ruling is a paragraph of prose, not a placeholder. Anything shorter is a stub.
MIN_RULING_CHARS = 200


def sections(text):
    """The evidence file as ``{heading: body}`` (the contract's `##` sections)."""
    out, current = {}, None
    for line in text.splitlines():
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            current = heading.group(1)
            out[current] = []
        elif current is not None:
            out[current].append(line)
    return {key: "\n".join(lines).strip() for key, lines in out.items()}


def fences(body):
    """Every fenced block in a section, in order, with its contents verbatim."""
    return [m.group(1) for m in re.finditer(r"^```[^\n]*\n(.*?)^```", body, re.S | re.M)]


def go_refs(node, where=""):
    """Every policy node carrying a non-empty ``fable_go_ref``, with its location and ref."""
    if isinstance(node, dict):
        ref = node.get("fable_go_ref")
        if isinstance(ref, str) and ref.strip():
            yield where or "/", node, ref.strip()
        for key, value in node.items():
            if key != "fable_go_ref":
                yield from go_refs(value, f"{where}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from go_refs(value, f"{where}[{index}]")


def problems(policy, root=GOS):
    """Every way the policy's GO claims and the evidence files disagree."""
    found = []
    refs = {}
    for where, node, ref in go_refs(policy):
        refs.setdefault(ref, []).append((where, node))
    for ref, claims in refs.items():
        matches = [path for path in sorted(root.glob("*.md"))
                   if ref in (sections(path.read_text(encoding="utf-8")).get("Approval ref") or "")]
        if len(matches) != 1:
            found.append(f"{ref}: {len(matches)} evidence files record this ref under "
                         f"{root.relative_to(ROOT) if root.is_relative_to(ROOT) else root} "
                         f"(claimed by {', '.join(where for where, _ in claims)})")
            continue
        path = matches[0]
        parts = sections(path.read_text(encoding="utf-8"))
        missing = [name for name in REQUIRED_SECTIONS if not parts.get(name)]
        if missing:
            found.append(f"{path.name}: missing {', '.join(missing)}")
            continue
        ruling = fences(parts["Ruling (verbatim)"])
        if not ruling or len(ruling[0].strip()) < MIN_RULING_CHARS:
            found.append(f"{path.name}: the ruling is not quoted verbatim")
        try:
            datetime.datetime.fromisoformat(parts["Date"].strip())
        except ValueError:
            found.append(f"{path.name}: {parts['Date'].strip()!r} is not a date")
        for where, node in claims:
            evidence = str(node.get("fable_go_evidence") or "").strip()
            if evidence != path.relative_to(ROOT).as_posix():
                found.append(f"{where}: fable_go_evidence is {evidence!r}, not {path.name!r}")
            # The GO approves ONE sentence. When the policy node carries that sentence, the
            # evidence has to quote that exact text - otherwise we have proven a ruling exists,
            # not that it approves the words we are about to send.
            text = node.get("text")
            if isinstance(text, str) and text:
                approved = fences(parts["Approved text"])
                if not approved or approved[0].rstrip("\n") != text:
                    found.append(f"{where}: the evidence file does not carry the approved text "
                                 f"verbatim ({text!r})")
    for path in sorted(root.glob("*.md")):
        parts = sections(path.read_text(encoding="utf-8"))
        if (parts.get("Approval ref") or "").strip("` \n") not in refs:
            found.append(f"{path.name}: records an approval no policy value cites")
    return found


class CopyGoEvidenceTest(unittest.TestCase):
    def test_every_cited_go_has_a_matching_evidence_file(self):
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        self.assertTrue(list(go_refs(policy)), "the policy cites no GO at all")
        self.assertEqual(problems(policy), [])

    def test_a_go_ref_with_no_evidence_file_is_refused(self):
        # The gate has to fail on a claim without a ruling, or it is decoration.
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        policy["offers"] = {"regional_suffix": {"text": " a price sentence",
                                                "fable_go_ref": "fable-ruling-9999-zz/never-granted"}}
        self.assertIn("fable-ruling-9999-zz/never-granted",
                      " ".join(problems(policy)))

    def test_an_evidence_file_that_quotes_different_copy_is_refused(self):
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        for _, node, _ in go_refs(policy):
            if "text" in node:
                node["text"] = " some other sentence we would like to send"
        self.assertTrue(any("approved text" in problem for problem in problems(policy)))


if __name__ == "__main__":
    unittest.main()
