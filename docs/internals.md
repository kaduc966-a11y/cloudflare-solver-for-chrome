# cfsolve internals (stage2 → verdict)

Mechanics behind the POST#2 verdict, for diagnosing recognizers and building profiles.
Line refs are this repo; they drift between builds — grep the symbol, don't trust the number.

## Pipeline

`disassemble → fold → discovery → Vocabulary::infer + Operation::recognize → payload → envelope → Trace`.
The server VM program (POST#1 response) is disassembled; string extraction (`vm/encoded_strings.rs`)
folds decoded values into the feature list; each probe is matched to a collector (`recognize`), then
its record is built (`records`) and packed (`envelope`) into POST#2.

## Treatment: Computed vs Replayed

`src/stage2/registry.rs` — every family is one of:
- **Computed** → collected LIVE this session (`operation.collect`). Not in answers.json.
- **Replayed** → a stored device fact from answers.json, patched to this session's field names.

The `families!` macro (`registry.rs`) is the source of truth. Build `7c7fee70a876` = **39
numbered probes = 16 Computed + 23 Replayed** (the 23 Replayed are exactly the answers.json keys).

Computed (reference index): worker_navigator[1], worker_fetch[4], private_token[5],
websocket_echo[6], parent_info[7], clock_resolution[8], dom_mutation[18], date_parsing_offsets[21],
network_information[25], stack[28], performance_entries[30], media[32], image[33], plus
`@empty [10,24,39]`. `benchmark` and `host_reachability` are Structural Computed with NO reference
index (extra collectors, not part of the 39).

Replayed (reference index): error_message_length[3], rects[29], and `@replayed`:
environment_audit[2], behavior[9], storage[11], high_entropy_user_agent[12], keyboard_layout[13],
intl[14], svg_geometry[15], native_inspection[16], summarizer_availability[17], emoji_color[19],
document_structure[20], isolation[22], computed_style_hash[23], math[26], font_enumeration[27],
document_summary[34], environment[35], console[36], graphics[37], audio[38], stylesheets[31].

**PAT (private_token[5]) is Computed** → never in answers.json; the solver replays its expected
token/timestamp from bytecode (see [chrome-fix.md](chrome-fix.md)). Do not "add PAT to answers".

## Record dispatch — `src/session/probes.rs`

```
probe.operation == None        → "probe N matches no known collector"   (recognizer failed)
Treatment::Replayed            → replay.answer(probe, stored)           (needs a stored answer)
Treatment::Computed            → operation.collect(facts, observed, engine)
                                 → vocabulary.rewrite_to_session(position, fields)
                                 → probe.writes.arrange(fields)
```
Each record is wrapped `answering probe N (family)`; `family` comes from `operation.family()`.

## Vocabulary — field names are session-randomized

Probe field names / pc / registers randomize per fetch. The stable key is the **reference index**.
`Vocabulary::partner(position)` maps this session's probe position → reference probe; replay reads
the stored answer by that partner (`replay.rs`). `rewrite_to_session` renames Computed
output fields back to this session's names. **Never hardcode pc/register/field-hash.**

`replay.answer` (`replay.rs`) failure:
`no stored answer for probe N (…); its strongest candidate is reference probe X (0.YY)` —
similarity below threshold → no partner → the probe can't be mapped. Usually a recognizer fell back
to generic Replay (below), not a missing answer.

## Generic Replay fallback (the misleading family)

`Operation::Replay { reference }` (`registry.rs`) is the catch-all when no specific recognizer
matches. Its `treatment()` = Replayed and `family()` = `Kind::from_reference` — so it REPORTS the
reference family (e.g. `websocket_echo`) even though it is only a generic replay. A "websocket_echo"
record that errors `no stored answer` is really an unrecognized probe, not a websocket_echo bug.
Fix the recognizer, not the answers.

## Recognizer traps (deep RE, not quick patches)

Recognizers live in `src/stage2/probes/*.rs`. Known fragile ones on new builds:
- **websocket_echo** — assumes field names interleaved with builtins; new builds hoist builtins to a
  header block and isolate field hashes → marker/`before()` extraction grabs builtins, returns None.
  Real fix = VM dataflow: the record is built by `Effect::SetProperty` with key `Reg(16)`, loaded by
  `Const(String)` just before each set. But the load is multi-path (branchy) → `dataflow::forward`
  meet DROPS the key. And the record lives in async closures (`onopen/onmessage/onerror/onclose`) →
  `index.function_range(entry)` covers one body only; enumerate closure entries
  (`index.dereference → Term::Closure`, recurse) and run per-path dataflow per closure.
- **empty** — dataflow matcher (`empty.rs`); a new probe variant (feature "eval", 3 writes) may not
  match. Dump the probe (`stage2_snapshot`) and inspect before patching.
- **worker_fetch / stack** — fixed on the new build (drop `credentials:"omit"` marker; runner-based
  dispatch disambiguation). Keep their tests green.

Toolkit that works: `empty.rs` (dataflow matcher), `stack.rs` (`effects_in` + `function_range` +
`dereference` + closure recursion), `network_information.rs` (reference-name anchoring — only for
probes whose fields ARE browser properties, not internal roles like websocket_echo).
After any recognizer change: keep `probes/*.rs::tests` green AND `compare_session` on an old capture.

## Profile tools (cargo examples, exact signatures)

- `build_profile <capture.json> [cssom.json] > answers.json` — decoded capture → stored answers;
  stamps `reference = REFERENCE.digest`. Writes only the Replayed probes.
- `fill_profile <base-profile.json> <capture-dir>... > profile.json` — `<capture-dir>` is the proxy
  `--out` ROOT (has `traffic.json` + `sessions/`); `Recording::read` (`capture/recorded.rs`)
  skips incomplete sessions. Fills UA/client-hints/header-order + measured sections
  (durations/benchmark/media/intervals/timeline). Does NOT change `browser`/`navigator`/`interaction`
  — override those from the capture when the base device differs. stderr notes say what was filled.
- `rebase_reference <capture.json> <old reference.json> <reference.rs> <new reference.json>` —
  rebuild reference.json on a rotated build, KEEP probe numbers; prints declaration translations.
  Update reference.rs names → recompile (digest changes) → build_profile.
- `check_answers <answers.json> <capture.json>...` — validate answers against capture(s).
- `compare_session <session-directory> <capture.json> [--values]` — diff a solver session vs a
  capture; regression check after recognizer edits.

## Digest coupling (build-match)

`REFERENCE.digest = format!("{:x}", Sha256::digest(include_str!("reference.json")))[..16]`
(`reference.rs`) is COMPILED INTO the binary. `Answers::capture` stamps it (`replay.rs`);
`Answers::check` requires `answers.reference == REFERENCE.digest` (`replay.rs`). So answers
always match the binary that BUILT them — NOT the live page. Two checkouts can share build label
`7c7fee70a876` / 39 probes yet have DIFFERENT digests (extraction differs). A `check` error naming
two digests = wrong binary/answers pairing, not a CF rotation.