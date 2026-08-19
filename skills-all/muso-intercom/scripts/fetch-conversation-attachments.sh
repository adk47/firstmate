#!/usr/bin/env bash
set -euo pipefail

# Downloads all attachments (structured + inline <img>) of an Intercom
# conversation to local files so agents can inspect them with vision.
#
# Intercom CDN attachment URLs are signed with a ~30-minute TTL, so this
# helper re-fetches the conversation fresh (never re-uses a URL captured
# earlier by a caller) to get live, unexpired URLs.
#
# node-8 has no `file` binary, so image/PDF type detection is done here via
# magic bytes (first $DETECT_SNIFF_BYTES bytes, hex-dumped with `od`) -- no
# external dependency beyond curl and jq. That window is 256, not just the
# header: a `ftyp` box carries an unbounded compatible-brand list and the brand
# that matters can sit past byte 32 (see DETECT_SNIFF_BYTES).
#
# HEIC/HEIF (every iPhone "High Efficiency" photo) is detected as ISO-BMFF --
# an `ftyp` box at offset 4 whose major brand, or one of its compatible
# brands, is in the HEIF family -- and then NORMALIZED to JPEG with
# `heif-convert` (Debian `libheif-examples`) so vision/OCR can read it.
# When the transcode is impossible (binary missing, corrupt input, timeout) or
# its output is too large to be useful (oversize), the original bytes are kept
# AND the manifest line carries `"unreadable": true` with a machine-readable
# reason. That marker is the
# ONLY evidence that licenses a human to say "the decoder failed" -- see
# workspaces/operations/skills/muso-clickup-ticket-sweeper/SKILL.md.
#
# Extraction mirrors plugins/intercom/src/filters.ts (extractImageAttachments
# / extractDocumentAttachments / INTERCOM_CDN_HOST_RE): structured
# attachments at .source.attachments[] and
# .conversation_parts.conversation_parts[].attachments[], plus inline
# <img src="..."> URLs scraped from the HTML .source.body and
# .conversation_parts.conversation_parts[].body -- deduped by URL, then
# filtered through the same CDN host allowlist.

usage() {
  cat <<'USAGE'
Usage: fetch-conversation-attachments.sh <conversation_id> [--out-dir DIR]

Downloads all attachments of an Intercom conversation to local files.

  <conversation_id>   Intercom conversation id (required).
  --out-dir DIR       Directory to download into. Default:
                       ./intercom-attachments/<conversation_id>/

Requires MUSOAI_INTERCOM_TOKEN in the environment.

Prints one compact JSON line per successfully downloaded attachment to
stdout:
  {"path":"...","source_url":"...","detected_type":"png","bytes":123}

HEIC/HEIF attachments are transcoded to JPEG (requires `heif-convert` from
the libheif-examples package); the line then also carries
"converted_from":"heic" and "original_path". An attachment whose bytes could
not be decoded is still reported, with "unreadable":true and
"unreadable_reason": one of heic_decode_failed | corrupt_or_unrecognized |
oversize | pipeline_failed. `corrupt_or_unrecognized` means only that the bytes
matched no format we know -- that is EITHER a damaged upload OR a valid file in
a format we cannot read, and this helper cannot tell which. Each line also
carries `declared_type`, the content-type the uploading client claimed, as a
hint that is NOT verified. `pipeline_failed` means OUR side never looked at
the file (transcoder not installed, or our own timeout); `heic_decode_failed`
means libheif looked and refused, which this script cannot distinguish between
a damaged upload and a variant we cannot decode. Override the binary with
INTERCOM_HEIF_CONVERT_BIN.

The transcode is bounded the same way the plugin path bounds it: a 12s
`timeout` (coreutils) around heif-convert, and a 10MB cap on the DERIVED JPEG
-- a 9MB high-resolution HEIC can decode into a far larger JPEG. Override with
INTERCOM_HEIF_CONVERT_TIMEOUT_SECS / INTERCOM_HEIF_CONVERT_MAX_BYTES.
USAGE
}

CONVERSATION_ID=""
OUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir)
      [ $# -ge 2 ] || { echo "--out-dir requires a value" >&2; exit 2; }
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$CONVERSATION_ID" ]; then
        CONVERSATION_ID="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [ -z "$CONVERSATION_ID" ]; then
  echo "Missing required argument: conversation_id" >&2
  usage >&2
  exit 2
fi

# Guard the id before it reaches a filesystem path (the default OUT_DIR embeds
# it) or the Intercom URL: it must be a plain id token, never a path fragment.
# This blocks `../` traversal in the default out-dir from a crafted argument.
if [[ ! "$CONVERSATION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Invalid conversation_id '${CONVERSATION_ID}': expected characters [A-Za-z0-9_-]." >&2
  exit 2
fi

: "${MUSOAI_INTERCOM_TOKEN:?MUSOAI_INTERCOM_TOKEN must be set to an Intercom Bearer token -- see skills-all/muso-intercom/SKILL.md}"

OUT_DIR="${OUT_DIR:-intercom-attachments/${CONVERSATION_ID}}"
mkdir -p "$OUT_DIR"

# CDN host allowlist -- mirrors plugins/intercom/src/filters.ts INTERCOM_CDN_HOST_RE
# (case-insensitive there; we lowercase the URL before matching to keep parity).
CDN_HOST_RE='^https://([a-z0-9-]+\.)*(intercomcdn\.(com|io)|intercom-attachments(-[0-9]+)?\.com)/'

# ISO-BMFF `ftyp` brands (hex) that mean "HEIF-family still image".
# heic heix heim heis hevc hevx heif mif1 msf1
HEIF_BRANDS_HEX="68656963 68656978 6865696d 68656973 68657663 68657678 68656966 6d696631 6d736631"

# Transcoder for HEIC/HEIF -> JPEG. Overridable for tests; mirrors the plugin's
# INTERCOM_HEIF_CONVERT_BIN so both attachment paths are configured the same way.
HEIF_CONVERT_BIN="${INTERCOM_HEIF_CONVERT_BIN:-heif-convert}"

# Bounds on the transcode, mirroring plugins/intercom/src/attachments.ts exactly
# -- ATTACHMENT_FETCH_TIMEOUT_MS (12_000) becomes 12s, ATTACHMENT_MAX_BYTES
# (10 * 1024 * 1024) is the same 10485760 already given to curl --max-filesize
# above. Not new limits: the plugin path bounds both and this one bounded
# neither, so a sub-10MB crafted or very high-resolution HEIC could hang the
# sweeper indefinitely or decompress into a JPEG far larger than the input and
# fill the disk. The INPUT being under the download cap says nothing about the
# DERIVED output -- libheif at -q 90 expands a high-megapixel HEIC severalfold.
HEIF_CONVERT_TIMEOUT_SECS="${INTERCOM_HEIF_CONVERT_TIMEOUT_SECS:-12}"
HEIF_CONVERT_MAX_BYTES="${INTERCOM_HEIF_CONVERT_MAX_BYTES:-10485760}"

# Both overrides are validated as strict positive decimals BEFORE anything runs,
# and a bad one is fatal rather than ignored.
#
# Why fatal: `[ "$primary_size" -gt "$HEIF_CONVERT_MAX_BYTES" ]` with a
# non-numeric bound makes `test` exit 2 ("integer expression expected"). That
# test is an `if` CONDITION, so `set -e` does not fire -- bash treats the
# non-zero status as "false", skips the refusal, and falls straight through to
# the `mv`. A typo'd override therefore SILENTLY DISABLES the cap it was meant
# to tune, which is the precise failure mode the cap exists to prevent. A guard
# that cannot parse its own limit must refuse, not wave the file through.
# `timeout` would likewise reject a bad duration, but at that point the work dir
# already exists -- rejecting both here keeps the failure at one place.
# Upper bounds exist because the digit check ALONE is not enough. `test -gt`
# evaluates its operands as 64-bit arithmetic, and a value bash cannot parse as
# an integer makes it exit 2 -- which, as an `if` CONDITION, reads as "false"
# and promotes the very file the cap was meant to refuse. So an override of
# 999999999999999999999999999999 defeats the guard exactly like `bogus` did.
# Range-checking closes that, and a ceiling is independently right: a 1 GiB
# derived-JPEG cap or a one-hour transcode is not a tuning, it is a mistake.
#
# The DIGIT-COUNT gate runs before the range comparison on purpose: comparing an
# over-wide string with `-gt` is the bug, so the check that catches it must not
# itself hand that string to `-gt`.
HEIF_CONVERT_TIMEOUT_SECS_MAX=3600
HEIF_CONVERT_MAX_BYTES_MAX=1073741824
for _bound in HEIF_CONVERT_TIMEOUT_SECS HEIF_CONVERT_MAX_BYTES; do
  _value="${!_bound}"
  _max_var="${_bound}_MAX"
  _max="${!_max_var}"
  if [ "$_bound" = HEIF_CONVERT_MAX_BYTES ]; then _unit=bytes; else _unit=seconds; fi
  # Whole token, anchored, no leading zeros/signs/spaces, and > 0. Anchoring
  # matters: an unanchored match accepts "12; rm -rf /" and "1e9".
  if [[ ! "$_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid ${_bound}='${_value}': expected a positive whole number of ${_unit}." >&2
    exit 2
  fi
  if [ "${#_value}" -gt "${#_max}" ] || [ "$_value" -gt "$_max" ]; then
    echo "Invalid ${_bound}='${_value}': must be between 1 and ${_max} ${_unit}." >&2
    exit 2
  fi
done
unset _bound _value _max_var _max _unit

# Bytes we dump for sniffing. A `ftyp` box carries an unbounded compatible-brand
# list, and the brand that matters can sit well past the header: a file with
# generic major brand `isom` and `heic` as its FIFTH compatible brand starts at
# byte 32. Reading only 32 bytes classified those as `unknown`, so a perfectly
# good iPhone photo was reported to Ops as `corrupt_or_unrecognized` -- a false
# claim about the customer's file, which is the exact thing the unreadable
# markers exist to prevent. 256 covers every real-world ftyp box while staying a
# bounded read; the declared box size caps the scan below.
DETECT_SNIFF_BYTES=256

detect_type() {
  local f="$1" hex brand off box_size scan_end
  hex="$(head -c "$DETECT_SNIFF_BYTES" "$f" | od -An -tx1 | tr -d ' \n')"
  case "$hex" in
    89504e47*) echo png; return ;;
    ffd8ff*) echo jpeg; return ;;
    47494638*) echo gif; return ;;
    25504446*) echo pdf; return ;;
  esac
  if [[ "$hex" == 52494646* && "${hex:16:8}" == "57454250" ]]; then
    echo webp
    return
  fi
  # ISO-BMFF: [4B box size][`ftyp` = 66747970][4B major brand][4B minor
  # version][compatible brands...]. Apple writes major brand `heic`, but
  # plenty of encoders write `mif1` major with `heic` merely in the compatible
  # list -- check BOTH or half the real-world files are missed.
  if [[ "${hex:8:8}" == "66747970" ]]; then
    # Mirror the TypeScript detector (attachments.ts detectImageFormatFromBytes):
    # honour the DECLARED box size so we never read brands belonging to the next
    # box, and clamp to what we actually dumped so a bogus size cannot spin us.
    # Each hex char is half a byte, hence the doubling.
    box_size=$((16#${hex:0:8}))
    scan_end=${#hex}
    if [ "$box_size" -ge 16 ] && [ $((box_size * 2)) -lt "$scan_end" ]; then
      scan_end=$((box_size * 2))
    fi
    # Major brand at byte 8 (hex offset 16).
    brand="${hex:16:8}"
    case " $HEIF_BRANDS_HEX " in
      *" $brand "*) echo heic; return ;;
    esac
    # Compatible brands from byte 16 (hex offset 32) onward, 4 bytes each.
    for (( off = 32; off + 8 <= scan_end; off += 8 )); do
      brand="${hex:$off:8}"
      case " $HEIF_BRANDS_HEX " in
        *" $brand "*) echo heic; return ;;
      esac
    done
  fi
  echo unknown
}

# Transcode a HEIC/HEIF file to JPEG. Echoes the JPEG path on success.
#
# Exit codes are DISTINCT because the caller reports them to a human as
# different facts: 1 = libheif READ the bytes and refused them ->
# heic_decode_failed; 2 = we decoded it fine and the result is too big to be
# useful evidence -> oversize; 3 = OUR side never got a verdict on the file at
# all (binary missing, our timeout, or a host-I/O failure creating the work dir
# or placing the output) -> pipeline_failed. Collapsing the second
# into the first would tell Ops "the decoder failed" about a file that decoded
# perfectly, which is exactly the false claim the unreadable markers exist to
# prevent.
#
# heif-convert's output naming is the first trap: for a single-image file it
# writes exactly the path you asked for, but for a MULTI-image file (every tiled
# Apple HEIC, and anything carrying depth/alpha auxiliary images) it ignores
# that and writes `<base>-1.jpg`, `<base>-2.jpg`, ... So the name cannot be
# predicted and the output has to be read back.
#
# WHERE it is read back from is the second trap, and the one that corrupts
# evidence. --out-dir defaults to a REUSED, deterministic directory
# (./intercom-attachments/<conversation_id>/) and the index restarts at 1 on
# every run, so scanning that directory mixes this run's outputs with every
# earlier run's: run 1 converts a single-image HEIC and leaves `1.jpg`; run 2
# converts a different, MULTI-image HEIC and writes only `1-1.jpg`/`1-2.jpg` --
# and a scan that prefers the existing exact `1.jpg` hands back RUN 1's photo
# as run 2's evidence. In a credit-verification path that is cross-customer
# contamination, not a stale cache.
#
# So: purge the names this function owns, convert inside a FRESH private
# directory, consider ONLY what that invocation wrote, move the chosen primary
# to `<base>.jpg`, and delete the rest with the work dir.
transcode_heic() {
  local src="$1" base="$2" work out primary candidate rc primary_size
  # Names this function owns from an earlier run. Removed up front so a FAILED
  # transcode cannot leave a previous run's JPEG sitting at `<base>.jpg`.
  rm -f "${base}.jpg" "${base}"-[0-9]*.jpg
  if ! command -v "$HEIF_CONVERT_BIN" >/dev/null 2>&1; then
    echo "heif-convert not found (install libheif-examples) -- keeping original ${src}" >&2
    return 3
  fi
  work="$(mktemp -d "${base}.convert.XXXXXX")" || {
    # Host I/O, not a verdict on the file: nothing has read the bytes yet.
    echo "could not create a work dir for ${src} -- keeping original" >&2
    return 3
  }
  out="$work/out.jpg"
  # `timeout` bounds the subprocess: an unbounded heif-convert on a crafted or
  # pathological HEIC hangs the whole sweep with no upper limit, and this script
  # runs unattended. rc 124 is timeout's "killed it"; every other non-zero is
  # libheif refusing the input. Both are heic_decode_failed to the caller, but
  # they are said differently on stderr so an operator can tell a bad file from
  # a wedged decoder.
  # `rc` is captured with `|| rc=$?`, NOT read inside an `if !` branch: `!`
  # inverts the status, so `$?` there is 0 and the timeout would be
  # indistinguishable from a decode error.
  rc=0
  timeout "${HEIF_CONVERT_TIMEOUT_SECS}s" "$HEIF_CONVERT_BIN" -q 90 "$src" "$out" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf "$work"
    # 3 = OUR fault, nothing looked at the payload (binary missing above, or our
    # own timeout budget). 1 = libheif looked and refused: that is EITHER a
    # damaged upload OR a variant we cannot decode, and this script cannot tell
    # which, so it must not claim either.
    if [ "$rc" -eq 124 ]; then
      echo "heif-convert timed out after ${HEIF_CONVERT_TIMEOUT_SECS}s on ${src} -- keeping original" >&2
      return 3
    fi
    echo "heif-convert failed on ${src} -- keeping original" >&2
    return 1
  fi
  # Only files THIS invocation produced are eligible -- the work dir was empty
  # a moment ago.
  primary=""
  if [ -s "$out" ]; then
    primary="$out"
  else
    # Multi-image output: out-1.jpg is the primary; the rest are auxiliary
    # (depth maps, alpha, thumbnails) and carry no support-relevant content.
    for candidate in "$work"/out-[0-9]*.jpg; do
      [ -s "$candidate" ] || continue
      primary="$candidate"
      break
    done
  fi
  if [ -z "$primary" ]; then
    echo "heif-convert produced no readable output for ${src} -- keeping original" >&2
    rm -rf "$work"
    return 1
  fi
  # Validate the DERIVED output before it is promoted or reported. Checked on
  # the work-dir file, not after the move: an oversized JPEG must never occupy
  # the canonical <base>.jpg name, or a later glob hands it to a caller as this
  # attachment's evidence even though we refused it.
  primary_size="$(wc -c <"$primary" | tr -d ' ')"
  if [ "$primary_size" -gt "$HEIF_CONVERT_MAX_BYTES" ]; then
    echo "transcoded JPEG for ${src} is ${primary_size} bytes, over the ${HEIF_CONVERT_MAX_BYTES}-byte cap -- keeping original" >&2
    rm -rf "$work"
    return 2
  fi
  if ! mv "$primary" "${base}.jpg"; then
    # The transcode SUCCEEDED; only our filesystem move failed. Reporting a
    # decode failure here would blame a file libheif read perfectly.
    echo "could not place the transcoded JPEG for ${src} -- keeping original" >&2
    rm -rf "$work"
    return 3
  fi
  # The auxiliary siblings die with the work dir.
  rm -rf "$work"
  printf '%s\n' "${base}.jpg"
}

CONVO_JSON="$(mktemp)"
cleanup() { rm -f "$CONVO_JSON"; }
trap cleanup EXIT

if ! curl -sS --fail-with-body \
    -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
    -H "Intercom-Version: 2.11" \
    -H "Accept: application/json" \
    -o "$CONVO_JSON" \
    "https://api.intercom.io/conversations/${CONVERSATION_ID}"; then
  echo "Failed to fetch conversation ${CONVERSATION_ID} from Intercom (non-2xx response):" >&2
  cat "$CONVO_JSON" >&2 || true
  exit 1
fi

if ! jq -e . "$CONVO_JSON" >/dev/null 2>&1; then
  echo "Conversation ${CONVERSATION_ID}: Intercom response was not valid JSON." >&2
  exit 1
fi

# jq program: extract candidate attachment URLs from both branches, dedupe.
read -r -d '' JQ_PROGRAM <<'JQEOF' || true
def structured_atts:
  ((.source.attachments // [])[] | {url: .url, content_type: (.content_type // null), name: (.name // null)}),
  ((.conversation_parts.conversation_parts // [])[] | (.attachments // [])[] | {url: .url, content_type: (.content_type // null), name: (.name // null)});

def inline_urls(body):
  (body // "") as $b
  | ( [$b | scan("<img[^>]*\\ssrc=\"([^\"]*)\"")] | map(.[0]) )
  + ( [$b | scan("<img[^>]*\\ssrc='([^']*)'")] | map(.[0]) );

([structured_atts]) as $structured
| ( inline_urls(.source.body)
    + ( [(.conversation_parts.conversation_parts // [])[]] | map(inline_urls(.body)) | add // [] )
  ) as $inline_raw
| ( $inline_raw | map(select(. != null and . != "")) | map({url: ., content_type: null, name: null}) ) as $inline
| ( $structured + $inline )
| map(select(.url != null and .url != ""))
| unique_by(.url)
JQEOF

CANDIDATES_JSON="$(jq -c "$JQ_PROGRAM" "$CONVO_JSON")"

total=0
downloaded=0
idx=0

while IFS= read -r cand; do
  total=$((total + 1))
  url="$(jq -r '.url' <<<"$cand")"
  # Intercom's DECLARED content_type. Not trusted to identify the bytes -- the
  # magic-byte sniff does that -- but it is the only thing that distinguishes
  # "a format we do not handle" from "damaged bytes" when the sniff comes back
  # unknown. The jq extractor has always captured it; the loop used to throw it
  # away.
  declared_ct="$(jq -r '.content_type // "" | ascii_downcase' <<<"$cand")"

  url_lc="${url,,}"
  if [[ ! "$url_lc" =~ $CDN_HOST_RE ]]; then
    echo "Skipping non-allowlisted attachment host: $url" >&2
    continue
  fi

  idx=$((idx + 1))
  tmp_file="$OUT_DIR/.tmp-${idx}"
  if ! curl -sS --fail-with-body \
      --max-filesize 10485760 \
      --connect-timeout 10 --max-time 60 \
      -o "$tmp_file" \
      "$url"; then
    echo "Failed to download attachment #${idx} (${url})." >&2
    rm -f "$tmp_file"
    continue
  fi

  detected="$(detect_type "$tmp_file")"
  # Single extension, always: the name is `<idx>.<type>`, never `<idx>.heic.heic`.
  dest="$OUT_DIR/${idx}.${detected}"
  mv "$tmp_file" "$dest"

  unreadable=false
  unreadable_reason=""
  converted_from=""
  original_path=""

  if [ "$detected" = heic ]; then
    if jpg_path="$(transcode_heic "$dest" "$OUT_DIR/${idx}")"; then
      converted_from=heic
      original_path="$dest"
      dest="$jpg_path"
      detected=jpeg
    else
      # `if !` would swallow the exit code, and the two failures are different
      # facts about the customer's file. Captured, then mapped 1:1 onto the same
      # reason vocabulary the plugin path uses (attachments.ts UnreadableReason).
      transcode_rc=$?
      # Keep the original bytes either way AND say what happened -- the sweeper
      # is forbidden from calling evidence "corrupt" without this marker, and
      # calling a perfectly decoded but oversized JPEG a decode failure would be
      # the same false claim in the other direction.
      unreadable=true
      case "$transcode_rc" in
        2) unreadable_reason=oversize ;;
        3) unreadable_reason=pipeline_failed ;;
        *) unreadable_reason=heic_decode_failed ;;
      esac
    fi
  elif [ "$detected" = unknown ]; then
    unreadable=true
    # ONE neutral state, deliberately.
    #
    # The previous version promoted the DECLARED type to a verdict about bytes
    # the detector had just failed to recognize: truncated garbage labelled
    # image/tiff became `unsupported_type` ("the file is FINE"), and a valid
    # inline TIFF with no declared MIME became `corrupt_or_unrecognized`
    # ("damaged"). Both are claims the code cannot support -- the declared type
    # is a hint from the uploading client, and the whole reason we sniff bytes
    # is that clients lie. Sniffing every unsupported container instead (TIFF,
    # MP4, ZIP, DOCX, ...) would be a real answer, but it is not this PR.
    #
    # So the reason stays exactly as wide as the evidence: we could not identify
    # these bytes. `declared_type` rides along in the manifest so Ops can see
    # what the client claimed WITHOUT the helper asserting it was true.
    unreadable_reason=corrupt_or_unrecognized
  fi

  size="$(wc -c <"$dest" | tr -d ' ')"

  jq -nc --arg path "$dest" --arg url "$url" --arg type "$detected" --argjson bytes "$size" \
    --argjson unreadable "$unreadable" --arg reason "$unreadable_reason" \
    --arg declared "$declared_ct" \
    --arg converted_from "$converted_from" --arg original_path "$original_path" \
    '{path: $path, source_url: $url, detected_type: $type, declared_type: $declared, bytes: $bytes}
     + (if $unreadable then {unreadable: true, unreadable_reason: $reason} else {} end)
     + (if $converted_from != "" then {converted_from: $converted_from, original_path: $original_path} else {} end)'
  downloaded=$((downloaded + 1))
done < <(jq -c '.[]' <<<"$CANDIDATES_JSON")

if [ "$total" -eq 0 ]; then
  echo "No attachments found in conversation ${CONVERSATION_ID}." >&2
  exit 0
fi

if [ "$downloaded" -eq 0 ]; then
  echo "Failed to download any of ${total} candidate attachment(s) for conversation ${CONVERSATION_ID}." >&2
  exit 1
fi

exit 0
