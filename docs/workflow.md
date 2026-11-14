# Workflow: capture → profile → verify

Turn a decoded real-Chrome capture into a profile that mints a server-accepted token with no real
browser, and diagnose why POST#2 returns interaction instead of complete.

## Decisive model: POST#1 trust decides 2-post vs 3-post

Cloudflare picks the program variant at **POST#1** from client trust:
- Trusted **Chrome desktop** fingerprint → **"complete"** program (~39 probes) → **POST#2 returns the token directly** (2-post).
- Less-trusted client (e.g. iOS Safari) → **"interaction"** program → POST#2 = interaction, POST#3 = complete (3-post).

The solver completes both. Program SIZE is not the signal (complete here is still ~2.13 MB).
`600010` is an umbrella "verification failed" verdict; HTTP 200 per request does not mean trust
passed. Do not chase "missing 2 probes" — the variant is chosen server-side. [observed]

## Two fixes that make the in-process complete path work

1. **New extraction `vm/encoded_strings.rs`** — runs the program's OWN decoder (factory + atob + XOR
   keystream) to fold decoded answer VALUES adjacent to field-name markers. The old
   `vm/masked_strings.rs` (PCmask 16-bit swap) decodes only API names → markers consecutive, no
   embedded values → name-table / decoder-call probes unresolved (`record token field not found`). [confirmed by source]
2. **PAT replay via `decoded_after`** — PrivateToken is Computed; its token/timestamp live only in
   bytecode. Replay the server-embedded expected values (`stage2/probes/private_token.rs`
   `token_value`/`timestamp_value`, read by `recognize.rs::decoded_after(marker)`) instead of
   computing live `SHA256(body)` / `finished_ms`. This avoids the stale-timestamp `/pat/` **400**; a
   fast release build gets the real **401 PrivateToken challenge**. `result` (`status_{status}`) and
   `elapsed` stay live. [observed]

Detail + evidence: [chrome-fix.md](chrome-fix.md).

## Steps

1. **Capture** a real-key Chrome desktop session (MITM recorder writes `capture.json` +
   `traffic.json`). A 2-post capture (2 POSTs; probe records `1..N` in payload 2) is the complete
   variant — ideal.
2. **Build answers + profile OFFLINE** (no new browser run): `scripts/build-chrome-profile.sh`
   (env `CFSOLVE_ROOT`, `CAPTURE_DIR`, `SESSION`, `BASE_PROFILE`, `OUT_NAME`). It runs:
   - `cargo run --release --example build_profile -- <capture.json> > profiles/<OUT>/answers.json`
   - `cargo run --release --example fill_profile -- <base.json> <CAPTURE_DIR> > profiles/<OUT>.json`
   - repoints `answers` → `<OUT>/answers.json`.
   Pick a base already matched to the capture device (Chrome transport, correct cores/window).
   `fill_profile` refreshes UA + measured values (durations/benchmark/media/intervals/timeline); it
   does NOT change `browser`/`navigator`/`interaction` — override those from the capture when the
   base differs.
3. **Build-match check**: answers `reference` must equal the binary's compiled-in
   `REFERENCE.digest = SHA256(reference.json text)[..16]` (`reference.rs`, `replay.rs check()`).
   `build_profile` stamps `REFERENCE.digest`, so answers always match the binary that built them —
   NOT the live page. A mismatch error naming two digests = wrong binary/answers pairing, not a
   build rotation.
4. **Verify** with the solver, fresh session dir, no proxy/WARP:
   `challenge --page <cap_url> <fresh-session> --solve --fingerprint profiles/<OUT>.json --sitekey <key>`
   Success log: `Recovered N ordered probes; N native` → `complete, token …` (POST#2 or POST#3) →
   siteverify **200**. Paste the raw log; never claim a token without verify 200.
5. **CF build rotated?** Re-capture Chrome → rebuild profile/answers. If probe families changed,
   `rebase_reference <capture.json> <old reference.json> <reference.rs> <new reference.json>` keeps
   probe numbers and prints declaration translations; update `reference.rs` names, recompile
   (digest changes), then `build_profile`. Never hardcode pc/register (per-fetch random).

## Diagnosis: POST#2 interaction / 600010

Read the verdict + probe recovery first (mechanics in [internals.md](internals.md)):
- `matches no known collector` / `no stored answer … reference probe X (0.YY)` → a recognizer fell
  back to generic Replay; fix the recognizer (dataflow), not the answers. Generic Replay's
  `family()` is misleading (shows the reference family, e.g. websocket_echo).
- `record token field not found` → extraction can't resolve the name-table/decoder → need
  `encoded_strings` (fix 1).
- All native but POST#2 interaction → trust/fingerprint or PAT signal: check `/pat/` status
  (400 stale vs 401 real), Chrome-desktop transport/UA coherence, `worker_fetch_rejected`,
  navigator/screen vs the capture.
- Treatment: **Computed** = live collect (PAT, WorkerFetch, Image, Benchmark…); **Replayed** = stored
  answer. PAT is Computed → not in answers.json.

## Rules

- Profiles/answers come from REAL captures; tokens are server-minted, single-use (~300 s), bound to
  sitekey+hostname, validated at siteverify. Nothing here forges or replays a token past siteverify.
- MITM CA / `--ignore-certificate-errors` only on a disposable capture profile, never a real user browser.
- Minimal edits; keep tests green; verify on old captures (`compare_session`) after recognizer changes.
- Live proof only: paste raw verify-200 logs. Tag claims [observed] / [confirmed by source] / (inferred).
- Windows: write source via Edit/Write, not Bash heredoc; `PYTHONIOENCODING=utf-8`; fresh session dir
  per run (else `session is not empty`).