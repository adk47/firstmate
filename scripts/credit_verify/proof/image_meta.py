"""F3a: image provenance - generator/editor software, edit history, C2PA.

Read straight from the container (PNG chunks, JPEG/WebP segments, the XMP
packet, C2PA JUMBF boxes) with Pillow and byte scans; exiftool adds fields
when it is installed. Rules (report §7.1, real-data notes §8):
  * an AI-generator marker (Software / CreatorTool, a C2PA or IPTC
    digitalSourceType of trained-algorithmic media, Stable Diffusion /
    ComfyUI generation chunks) -> hard: the "screenshot" was generated;
  * image-editor software or an XMP edit history on a SCREENSHOT (no camera
    EXIF) -> soft: edited or exported, not proof of forgery on its own;
  * camera provenance (C2PA digitalCapture) -> positive;
  * missing EXIF is NORMAL (98% of real proofs are screenshots) and is never
    a flag.
The C2PA manifest's signature is not cryptographically validated here (no
c2pa tool on the host); its presence and declared source type are read from
the manifest bytes, which is enough to catch a generator that announces itself.
"""

from __future__ import annotations

import io
import json
import re
import shutil
import subprocess
import zlib
from typing import Any

from .signals import HARD, INFO, POSITIVE, SOFT, Evidence, Signal

TOOL = "credit_verify.image_meta"

AI_SOFTWARE = re.compile(
    r"gpt[- ]?image|dall[\s·\-]?e|midjourney|firefly|stable[\s-]?diffusion|comfyui|novelai|automatic1111|"
    r"invokeai|imagen|ideogram|leonardo\.?ai|made with (google )?ai|flux(\.1)?[\s-]?(dev|pro|schnell)|sdxl",
    re.I)
EDITOR_SOFTWARE = re.compile(r"photoshop|gimp|canva|pixelmator|affinity|paint\.net|photopea|lightroom|snapseed|"
                             r"picsart|fotor|befunky|ps express", re.I)
AI_SOURCE_TYPES = ("trainedAlgorithmicMedia", "compositeWithTrainedAlgorithmicMedia", "algorithmicMedia",
                   "compositeSynthetic")
CAPTURE_SOURCE = "digitalCapture"
C2PA_GENERATORS = re.compile(rb"(OpenAI|ChatGPT|gpt-image|DALL|Adobe Firefly|Firefly|Google|Microsoft|Meta AI|"
                             rb"Midjourney|Stability|Truepic|Leica|Sony|Nikon|Samsung|Pixel)")


def _png_chunks(data: bytes) -> list[tuple[bytes, bytes, int]]:
    out = []
    i = 8
    while i + 8 <= len(data):
        n = int.from_bytes(data[i:i + 4], "big")
        typ = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + n]
        out.append((typ, body, i))
        i += 12 + n
        if typ == b"IEND" or n < 0:
            break
    return out


def _png_text(chunks: list[tuple[bytes, bytes, int]]) -> dict[str, str]:
    texts: dict[str, str] = {}
    for typ, body, _ in chunks:
        try:
            if typ == b"tEXt":
                k, _, v = body.partition(b"\0")
                texts[k.decode("latin-1")] = v.decode("latin-1", "replace")
            elif typ == b"zTXt":
                k, _, rest = body.partition(b"\0")
                texts[k.decode("latin-1")] = zlib.decompress(rest[1:]).decode("latin-1", "replace")
            elif typ == b"iTXt":
                k, _, rest = body.partition(b"\0")
                comp, _method, rest = rest[0], rest[1], rest[2:]
                _lang, _, rest = rest.partition(b"\0")
                _tkey, _, txt = rest.partition(b"\0")
                if comp:
                    txt = zlib.decompress(txt)
                texts[k.decode("latin-1")] = txt.decode("utf-8", "replace")
        except (zlib.error, IndexError, ValueError):
            continue
    return texts


def _xmp(data: bytes) -> str | None:
    a = data.find(b"<x:xmpmeta")
    if a < 0:
        a = data.find(b"<rdf:RDF")
    if a < 0:
        return None
    b = data.find(b"</x:xmpmeta>", a)
    if b < 0:
        b = data.find(b"</rdf:RDF>", a)
    if b < 0:
        return None
    return data[a:b + 12].decode("utf-8", "replace")


def _c2pa_regions(data: bytes, mime: str) -> list[tuple[int, int]]:
    """Byte ranges of C2PA manifest stores (PNG caBX chunk, JPEG APP11 JUMBF,
    or any JUMBF box labelled c2pa)."""
    regions: list[tuple[int, int]] = []
    if mime == "image/png":
        for typ, body, off in _png_chunks(data):
            if typ == b"caBX":
                regions.append((off, off + 12 + len(body)))
    if not regions:
        for m in re.finditer(rb"jumb.{0,40}?c2pa", data, re.S):
            regions.append((max(0, m.start() - 8), min(len(data), m.start() + 200_000)))
            break
    return regions


def exif_fields(data: bytes) -> dict[str, Any]:
    try:
        from PIL import Image
    except ImportError:
        return {"_error": "pillow unavailable"}
    out: dict[str, Any] = {}
    try:
        with Image.open(io.BytesIO(data)) as im:
            out["width"], out["height"] = im.size
            ex = im.getexif()
            for tag, name in ((0x0131, "Software"), (0x010F, "Make"), (0x0110, "Model"), (0x0132, "DateTime")):
                if ex.get(tag):
                    out[name] = str(ex.get(tag))[:120]
            sub = ex.get_ifd(0x8769) if ex else {}
            if sub.get(0x9003):
                out["DateTimeOriginal"] = str(sub.get(0x9003))
    except Exception as exc:  # noqa: BLE001 - a malformed file is a recorded error, not a crash
        out["_error"] = f"{type(exc).__name__}: {exc}"[:200]
    return out


def exiftool_fields(data: bytes, timeout: int = 20) -> dict[str, Any] | None:
    """None when exiftool is not installed (optional tool); {"_error": ...}
    when it is installed but could not read the file. exiftool reads the
    bytes on stdin: the sandboxed child cannot open the host path."""
    exe = shutil.which("exiftool")
    if not exe:
        return None
    try:
        p = subprocess.run([exe, "-j", "-G1", "-a", "-n", "-Software", "-CreatorTool", "-HistorySoftwareAgent",
                            "-DigitalSourceType", "-Make", "-Model", "-DateTimeOriginal", "-"],
                           input=data, capture_output=True, timeout=timeout, check=False)
        rows = json.loads(p.stdout or b"[]")
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        return {"_error": f"{type(exc).__name__}: {exc}"[:200]}
    if p.returncode != 0 or not rows:
        return {"_error": f"exiftool rc={p.returncode}: {p.stderr.decode('utf-8', 'replace').strip()[-160:]}"}
    return rows[0]


def analyze(data: bytes, path: str, mime: str, decoded: bytes | None = None) -> tuple[list[Signal], dict[str, Any]]:
    """Returns (signals, facts). facts.camera tells later checks whether the
    image is a photo (camera EXIF) or a screenshot/export. `decoded` is a
    Pillow-readable copy (HEIC -> JPEG with its EXIF) used for EXIF only; XMP
    and C2PA are always read from the original bytes."""
    sig: list[Signal] = []
    ev = lambda **kw: Evidence(file=path, tool=TOOL, **kw)  # noqa: E731
    exif = exif_fields(decoded if decoded is not None else data)
    if "_error" in exif:
        sig.append(Signal("F3a", "metadata_unreadable", "error", value=exif["_error"], evidence=ev()))
    texts: dict[str, str] = {}
    if mime == "image/png":
        texts = _png_text(_png_chunks(data))
    xmp = _xmp(data)
    tool_fields = exiftool_fields(data) or {}
    if "_error" in tool_fields:
        sig.append(Signal("F3a", "exiftool_failed", "error", value=tool_fields.pop("_error"),
                          evidence=Evidence(file=path, tool="exiftool")))
    camera = bool(exif.get("Make") or exif.get("Model") or exif.get("DateTimeOriginal"))

    software_vals: list[tuple[str, str]] = []
    if exif.get("Software"):
        software_vals.append(("EXIF Software", exif["Software"]))
    for k in ("Software", "Comment", "Description", "Source", "Title"):
        if texts.get(k):
            software_vals.append((f"PNG {k}", texts[k][:200]))
    for k, v in tool_fields.items():
        if isinstance(v, str) and k.split(":")[-1] in ("Software", "CreatorTool", "HistorySoftwareAgent"):
            software_vals.append((f"exiftool {k}", v[:200]))
    if xmp:
        for m in re.finditer(r"(?:CreatorTool|softwareAgent)[=>\"]+([^<\"]{1,120})", xmp):
            software_vals.append(("XMP " + ("CreatorTool" if "Creator" in m.group(0) else "softwareAgent"), m.group(1)))

    for where, val in software_vals:
        if AI_SOFTWARE.search(val):
            sig.append(Signal("F3a", "ai_generator_software", HARD, value=val[:120],
                              reason="The image file says it was made by an AI image generator.",
                              evidence=ev(excerpt=where)))
        elif EDITOR_SOFTWARE.search(val):
            sig.append(Signal("F3a", "editor_software" if camera else "editor_software_on_screenshot",
                              INFO if camera else SOFT, value=val[:120], evidence=ev(excerpt=where)))
    if texts.get("parameters") and re.search(r"Steps:\s*\d+.*Sampler:", texts["parameters"], re.S):
        sig.append(Signal("F3a", "ai_generation_parameters", HARD, value="Stable Diffusion parameters chunk",
                          reason="The image file carries AI image-generation settings.", evidence=ev(excerpt="PNG parameters")))
    for k in ("prompt", "workflow"):
        if texts.get(k) and texts[k].lstrip().startswith("{"):
            sig.append(Signal("F3a", "ai_generation_workflow", HARD, value=f"ComfyUI {k} chunk",
                              reason="The image file carries AI image-generation settings.", evidence=ev(excerpt=f"PNG {k}")))
    if xmp:
        for st in AI_SOURCE_TYPES:
            if re.search(r"DigitalSourceType[^<]{0,80}" + st, xmp, re.I) or st in xmp:
                sig.append(Signal("F3a", "iptc_ai_source_type", HARD, value=st,
                                  reason="The image declares itself AI-generated.", evidence=ev(excerpt="XMP DigitalSourceType")))
                break
        hist = re.findall(r"stEvt:action[=>\"]+(\w+)", xmp)
        if hist and not camera:
            sig.append(Signal("F3a", "xmp_edit_history_on_screenshot", SOFT, value={"actions": hist[:10]},
                              evidence=ev(excerpt="XMP xmpMM:History")))
        elif hist:
            sig.append(Signal("F3a", "xmp_edit_history", INFO, value={"actions": hist[:10]}, evidence=ev(excerpt="XMP xmpMM:History")))
    for k, v in tool_fields.items():
        if k.endswith("DigitalSourceType") and isinstance(v, str) and any(t.lower() in v.lower() for t in AI_SOURCE_TYPES):
            sig.append(Signal("F3a", "iptc_ai_source_type", HARD, value=v[:120],
                              reason="The image declares itself AI-generated.", evidence=ev(excerpt=f"exiftool {k}")))

    for start, end in _c2pa_regions(data, mime):
        blob = data[start:end]
        gens = sorted({g.decode("latin-1") for g in C2PA_GENERATORS.findall(blob)})
        ai = [t for t in AI_SOURCE_TYPES if t.encode() in blob]
        if ai:
            sig.append(Signal("F3a", "c2pa_ai_source", HARD, value={"source_types": ai, "generators": gens},
                              reason="The image's content credentials say it was generated by AI.",
                              evidence=ev(byte_range=[start, end], excerpt="C2PA manifest")))
        elif CAPTURE_SOURCE.encode() in blob:
            sig.append(Signal("F3a", "c2pa_camera_capture", POSITIVE, value={"generators": gens},
                              evidence=ev(byte_range=[start, end], excerpt="C2PA manifest")))
        else:
            sig.append(Signal("F3a", "c2pa_manifest", INFO, value={"generators": gens},
                              evidence=ev(byte_range=[start, end], excerpt="C2PA manifest")))
        break

    sig.append(Signal("F3a", "camera_exif" if camera else "no_camera_exif", INFO,
                      value={k: exif[k] for k in ("Make", "Model", "DateTimeOriginal", "Software") if k in exif} or None,
                      evidence=ev()))
    # Deduplicate (several fields can carry the same generator name).
    seen: set[tuple[str, str]] = set()
    uniq = []
    for s in sig:
        key = (s.name, json.dumps(s.value, sort_keys=True, default=str))
        if key not in seen:
            seen.add(key)
            uniq.append(s)
    return uniq, {"camera": camera, "width": exif.get("width"), "height": exif.get("height"),
                  "exiftool": bool(tool_fields), "exif_datetime": exif.get("DateTime"),
                  "exif_datetime_original": exif.get("DateTimeOriginal"),
                  "software": next((v[:120] for _, v in software_vals), None)}
