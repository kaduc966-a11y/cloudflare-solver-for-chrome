#!/bin/bash
# Build a cfsolve Chrome profile + answers OFFLINE from an existing decoded capture (no browser run).
# Runs build_profile + fill_profile, then repoints "answers" preserving JSON formatting.
#
# Required env:
#   CFSOLVE_ROOT  cfsolve checkout (has Cargo.toml, examples/, profiles/)
#   CAPTURE_DIR   proxy --out ROOT (has traffic.json + sessions/<SESSION>/capture.json)
# Optional env:
#   SESSION       default session-0000
#   BASE_PROFILE  default profiles/chromium.json (relative to CFSOLVE_ROOT); pick a base
#                 already matched to the capture device (transport/cores/window)
#   OUT_NAME      default chromium  -> profiles/<OUT_NAME>.json + profiles/<OUT_NAME>/answers.json
set -e

die() { echo "ERROR: $*" >&2; exit 1; }
abspath() { case "$1" in /*|[A-Za-z]:/*) printf '%s\n' "$1";; *) printf '%s\n' "$PWD/$1";; esac; }

[ -n "$CFSOLVE_ROOT" ] || die "set CFSOLVE_ROOT (cfsolve checkout)"
[ -n "$CAPTURE_DIR" ]  || die "set CAPTURE_DIR (proxy --out root with traffic.json + sessions/)"
ROOT="$(abspath "$CFSOLVE_ROOT")"
CAP="$(abspath "$CAPTURE_DIR")"
SESSION="${SESSION:-session-0000}"
OUT_NAME="${OUT_NAME:-chromium}"
BASE_PROFILE="${BASE_PROFILE:-profiles/chromium.json}"
case "$BASE_PROFILE" in /*|[A-Za-z]:/*) BASE="$(abspath "$BASE_PROFILE")";; *) BASE="$ROOT/$BASE_PROFILE";; esac

[ -f "$ROOT/Cargo.toml" ] || die "no Cargo.toml under CFSOLVE_ROOT=$ROOT"
CAPJSON="$CAP/sessions/$SESSION/capture.json"
[ -f "$CAPJSON" ]      || die "missing $CAPJSON"
[ -f "$CAP/traffic.json" ] || die "missing $CAP/traffic.json (CAPTURE_DIR must be the proxy --out root)"
[ -f "$BASE" ]         || die "missing base profile $BASE"
command -v cargo >/dev/null 2>&1 || die "cargo not on PATH"
PY="$(command -v python || command -v python3)" || die "python not on PATH"

cd "$ROOT"
mkdir -p "profiles/$OUT_NAME"
ANSWERS="profiles/$OUT_NAME/answers.json"
PROFILE="profiles/$OUT_NAME.json"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

echo "[1/3] build_profile -> $ANSWERS"
if ! cargo run --release --quiet --example build_profile -- "$CAPJSON" > "$ANSWERS" 2>"$LOG"; then
  tail -n 25 "$LOG" >&2; die "build_profile failed"
fi
[ -s "$ANSWERS" ] || die "build_profile wrote an empty answers.json"

echo "[2/3] fill_profile (base=$BASE_PROFILE) -> $PROFILE"
if ! cargo run --release --quiet --example fill_profile -- "$BASE" "$CAP" > "$PROFILE" 2>"$LOG"; then
  tail -n 25 "$LOG" >&2; die "fill_profile failed"
fi
[ -s "$PROFILE" ] || die "fill_profile wrote an empty profile.json"
# fill_profile notes (what was filled / left out) go to stderr; surface them.
cat "$LOG" >&2

echo "[3/3] repoint answers -> $OUT_NAME/answers.json"
PYTHONIOENCODING=utf-8 "$PY" - "$PROFILE" "$OUT_NAME" "$ANSWERS" <<'PYEOF'
import re, sys, json
profile, out_name, answers = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(profile, 'rb').read().decode('utf-8')
new, n = re.subn(r'("answers"\s*:\s*")[^"]*(")',
                 lambda m: m.group(1) + out_name + '/answers.json' + m.group(2),
                 raw, count=1)
if n != 1:
    print("ERROR: no \"answers\" key found in profile", file=sys.stderr); sys.exit(1)
open(profile, 'wb').write(new.encode('utf-8'))
ans = json.load(open(answers, encoding='utf-8'))
prof = json.loads(new)
nav = ans.get('navigator', {})
probes = ans.get('probes', {})
print("OK profile written:")
print("  profile      :", profile)
print("  answers      :", prof.get('answers'))
print("  reference    :", ans.get('reference'))
print("  stored probes:", len(probes) if isinstance(probes, dict) else 'n/a')
print("  emulation    :", prof.get('transport', {}).get('profile'))
print("  userAgent    :", nav.get('userAgent'))
print("  platform     :", nav.get('platform'), "| cores:", nav.get('hardwareConcurrency'), "| mem:", nav.get('deviceMemory'), "| langs:", nav.get('languages'))
print("Next: verify with the solver, no real browser, FRESH session dir, no WARP:")
print("  challenge --page <cap_url> <fresh-session> --solve --fingerprint", profile, "--sitekey <key>")
print("Require siteverify 200 before claiming a token. answers.reference must equal the binary's compiled REFERENCE.digest.")
PYEOF