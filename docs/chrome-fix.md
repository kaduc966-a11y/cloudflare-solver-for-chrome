# Chrome fix (in-process complete token)

Verified 2026-11-14 against a live Cloudflare Turnstile widget (`siteverify` **200**, ~16 s
end-to-end). No real browser and no headless Chrome on the success path.

## Outcome [observed]

The server chooses the program variant at POST#1 from client trust, so the same Chrome desktop
profile has been served both variants; the solver completes both:

- **complete** program → token returned directly at POST#2 (2-post).
- **interaction** program → POST#2 = interaction (checkbox + proof worker), POST#3 = complete (3-post).

Most recent verified run (interaction variant):

```
Built a 48-field payload for this session
POST returned HTTP 200 OK; saved 2128140 bytes
Recovered 39 ordered probes; 39 have native collection implementations
POST returned HTTP 200 OK; saved 276844 bytes
Second response: interaction required; checkbox and proof worker returned
POST returned HTTP 200 OK; saved 8540 bytes
Third response: complete, token <redacted>
Captcha verify status: 200 len=880
```

Program SIZE is not the signal (the complete program is still ~2.1 MB). `600010` is an umbrella
"verification failed" verdict; HTTP 200 per request does not mean trust passed. Do not chase
"missing 2 probes" — the variant is chosen server-side.

## Root cause

Two solver-side defects previously blocked the complete path even with a Chrome profile:

### 1. Extraction could not resolve the new build's name-table

Build `7c7fee70a876` captures the record key name-table in a closure and computes token/input
through multi-level decoder calls; field names/constants/pc layout randomize per fetch. The old
`vm/masked_strings.rs` (PCmask 16-bit-key-swap XOR) decodes only API names, leaving markers
consecutive with no embedded values → `record token field not found` (envelope.rs).

The new `vm/encoded_strings.rs` runs the program's own decoder (factory + atob + XOR keystream)
and folds decoded answer VALUES into the feature list adjacent to each field-name marker
(PAT probe: 161 strings vs the old 690). This resolves the name-table and decoder calls. [confirmed by source]

### 2. PAT computed live → stale timestamp → /pat/ 400

PrivateToken is a **Computed** probe (not in answers.json). Its worker fetches
`/pat/{ray}/{timestamp}/{hash}/{input}`; the timestamp is baked into the static `url_path` at
analysis time. The old collector computed `token = SHA256(body)` and `timestamp = finished_ms`
live. A slow debug build (~72 s analysis) made the timestamp stale → `/pat/` returned **400**
(empty body) → PAT failed → POST#2 interaction.

The fix replays the server-embedded expected values, read immediately after each field-name
marker in the program string pool:

- `src/stage2/probes/private_token.rs`: `Fields { token_value, timestamp_value, url_path,
  platform_property }`; `collect()` emits `json!(self.token_value)` / `json!(self.timestamp_value)`;
  `result` stays live `format!("status_{status}")`, `elapsed` stays live.
- `src/stage2/analysis/recognize.rs`:
  ```rust
  pub(crate) fn decoded_after(&self, text: &str) -> Option<String> {
      let pair = self.features.windows(2).find(|pair| pair[0] == text)?;
      listing::decode_string(&pair[1], "").ok()
  }
  ```
  `recognize()` sets `token_value: strings.decoded_after(reference::PRIVATE_TOKEN_TOKEN)?`,
  `timestamp_value: strings.decoded_after(reference::PRIVATE_TOKEN_TIMESTAMP)?`.
- Markers (`src/stage2/reference.rs`): `PRIVATE_TOKEN_TOKEN`, `PRIVATE_TOKEN_TIMESTAMP`.

`decoded_after` only works with the new extraction (values adjacent to markers). A fast release
build keeps the PAT timestamp fresh → `/pat/` returns the real **401** with
`www-authenticate: PrivateToken challenge` → PAT passes. [observed]

Porting `decoded_after` onto the OLD extraction returns garbage (the marker's own tail), causing
`collector overwrote record field …`. The extraction must come first.

## Offline profile build (no new browser run)

Source: a decoded real Chrome desktop capture (`<CAPTURE_DIR>/sessions/session-0000/capture.json`
plus `traffic.json`), Chrome/157 Win32, 12 cores, deviceMemory 8, pl-PL. The profile tools read it
directly via `capture::Recording::read`.

```bash
cd <repo-root>
cargo run --release --example build_profile -- \
  <CAPTURE_DIR>/sessions/session-0000/capture.json > profiles/chromium/answers.json
cargo run --release --example fill_profile -- \
  profiles/chromium.json <CAPTURE_DIR> > profiles/chromium.json
# then set "answers": "chromium/answers.json" in profiles/chromium.json
```

- `build_profile` → 23 stored probes, `reference = e25ccf38995a05af`, navigator capture-matched.
  PAT is Computed → not stored; the solver replays it from bytecode at solve time.
- Pick a base profile already matched to the capture device (transport/cores/window);
  `fill_profile` refreshes UA + measured sections but does NOT change `browser`/`navigator`/`interaction`.
- `scripts/build-chrome-profile.sh` automates all three steps.

## Build-match (digest coupling)

`REFERENCE.digest = format!("{:x}", Sha256::digest(include_str!("reference.json")))[..16]`
is compiled into the binary (`reference.rs`). `Answers::capture` stamps
`reference: REFERENCE.digest.clone()` (`replay.rs`); `Answers::check` ensures
`answers.reference == REFERENCE.digest` (`replay.rs`). So answers always match the binary
that built them. Two checkouts can share build label `7c7fee70a876` / 39 probes but DIFFERENT digests
because the extraction differs (masked vs encoded). A `check` failure naming two digests is a
binary/answers pairing error, not a live-page rotation.

## File map

- Binary: `target/release/challenge` (`.exe` on Windows), reference `e25ccf38995a05af`.
- Profile + answers: `profiles/chromium.json`, `profiles/chromium/answers.json`.
- PAT fix: `src/stage2/probes/private_token.rs`, `src/stage2/analysis/recognize.rs`.
- Extraction: `src/vm/encoded_strings.rs` (fold called in `src/vm/disassemble.rs`).
- Reference: `src/stage2/reference.rs` + `reference.json`; `src/stage2/replay.rs`.
- Tools: `examples/{build_profile,fill_profile,rebase_reference,check_answers,compare_session}.rs`.

## Limits

- answers/reference are bound to build `7c7fee70a876`. On rotation, re-capture Chrome and rebuild;
  if probe families changed, `rebase_reference` then recompile. Never hardcode pc/register.
- To refresh an older checkout: port `encoded_strings` + PAT replay, regenerate reference.json +
  answers from a fresh capture (digest changes → recompile).