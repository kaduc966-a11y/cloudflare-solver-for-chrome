# cloudflare-solver-for-chrome

Cloudflare **Turnstile** solver tuned for a **Chrome desktop** fingerprint. It mints a
server-accepted token with **no real browser and no headless Chrome**. The server picks the program
variant from client trust: the *complete* program returns the token at **POST #2**; the *interaction*
program (checkbox + proof worker) is completed in-process and returns the token at **POST #3**. The
solver handles both.

```
POST #1  (48-field environment payload)  ->  server VM program
POST #2  (probe records)                 ->  complete: token  OR  interaction required
POST #3  (interaction proof, if needed)  ->  complete: token
```

The Chrome desktop profile recovers all **39 probes** and completes whichever program the server
serves — verified end-to-end both ways (`siteverify` 200, ~16-20 s). The token is minted by
Cloudflare, single-use (~300 s), bound to sitekey + hostname, and validated at `siteverify`.
Nothing here forges or replays a token.

## Attribution

Based on **[cfsolve](https://github.com/chris124567/cfsolve)** by Christopher Tarry, MIT licensed
(see [LICENSE](LICENSE)). The solver itself, the `src/vm/encoded_strings.rs` extraction, and the PAT
(Private Access Token) replay (`src/stage2/analysis/recognize.rs::decoded_after`,
`src/stage2/probes/private_token.rs`) are **upstream work** — this repo does not claim them.
`src/stage2/reference.rs` is unchanged from upstream.

What this repo adds on top:

- **A capture-matched Chrome desktop profile** — `profiles/chromium.json` +
  `profiles/chromium/answers.json`, built offline from a real Chrome 157 desktop capture. It presents
  a Chrome desktop fingerprint that recovers all 39 probes and completes the interaction program
  in-process (token at POST #3, `siteverify` 200).
- A one-line compile fix in `src/stage2/benchmark.rs` (the `deobfuscate` module path).

## Requirements

- Rust pinned in [`rust-toolchain.toml`](rust-toolchain.toml) (`rustup` installs it automatically).
- **CMake**, a **C/C++ compiler**, **libclang**, and **Git** — to patch and build BoringSSL
  (the vendored `btls-sys` / `wreq` / `http2` crates under `vendor/` send Chrome's ClientHello).
- Python 3 (optional) for the `solve.py` convenience runner.

## Build

```sh
cargo build --release --bin challenge
```

The solver binary is `target/release/challenge` (`.exe` on Windows). `cfsolve` (the default bin) is
only the deobfuscator; `capture-proxy` is the optional MITM recorder used to build profiles.

## Run

```sh
./target/release/challenge --page 'https://example.com/login' ./out-session \
  --solve --fingerprint profiles/chromium.json --sitekey 'SITEKEY'
```

- Prints the **token** to stdout; progress/logs go to stderr.
- The output directory must be **new or empty** (it holds the session's requests/responses).
- `--sitekey` selects a widget when the page has several; omit it to solve the first widget.
- Only have a sitekey? Add `--blank-page` and set `--page` to the site's real URL.
- Optional `--proxy <url>` (http/https/socks5/socks5h). No proxy is required.

Or use the runner (fresh temp dir each call, optional siteverify):

```sh
python solve.py 'https://example.com/login' --sitekey 'SITEKEY'
python solve.py 'https://example.com/login' --sitekey 'SITEKEY' --verify 'SITEVERIFY_SECRET'
```

## The Chrome profile

`profiles/chromium.json` → `profiles/chromium/answers.json`:

| Field | Value |
| --- | --- |
| User agent | Chrome/157.0.0.0, Windows NT 10.0; Win64; x64 |
| TLS emulation | `chrome_149` (windows) |
| navigator | platform Win32, 12 cores, deviceMemory 8, langs pl-PL/pl/en-US/en |
| reference digest | `e25ccf38995a05af` |
| stored probes | 23 (Replayed); 16 Computed collected live (incl. PAT) |
| CF build | `7c7fee70a876` (39 probes) |

**Build-bound.** `answers.reference` must equal the binary's compiled-in
`REFERENCE.digest = SHA256(reference.json)[..16]`. The profile matches the binary that built it, not
the live page. When Cloudflare rotates the build, re-capture a real Chrome session and rebuild:

```sh
cargo run --release --example build_profile  -- <capture.json> > profiles/chromium/answers.json
cargo run --release --example fill_profile   -- profiles/chromium.json <capture-dir> > profiles/chromium.json
# if probe families changed: rebase_reference, update src/stage2/reference.rs, recompile
```

`<capture-dir>` is a `capture-proxy --out` root (`traffic.json` + `sessions/`). PAT is Computed, so it
is never stored in answers — the solver replays it from the program bytecode at solve time.

## Layout

```
src/            solver library + bins (challenge, capture-proxy) and the VM/stage2 analysis
vendor/         patched btls-sys / wreq / http2 (Chrome ClientHello) — required by [patch.crates-io]
examples/       build_profile, fill_profile, rebase_reference, check_answers, compare_session, ...
profiles/       chromium.json + chromium/answers.json (the optimized Chrome profile)
scripts/        capture_cssom.mjs / serve_cssom.py (profile-building helpers)
solve.py        minimal URL -> token runner
```

## Responsible use

For authorized testing, research, and automation you are permitted to run. Respect the target site's
terms of service and applicable law. Tokens are server-minted and server-validated; this tool
automates a Chrome fingerprint, it does not bypass `siteverify` or forge tokens.

## License

MIT — see [LICENSE](LICENSE). Upstream cfsolve Copyright (c) 2026 Christopher Tarry.
Sửa bởi sagiri7284 [XDBG].