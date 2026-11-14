#!/usr/bin/env python3
"""Browserless Cloudflare Turnstile solver (Chrome desktop profile).

Usage:
  python solve.py <page-url> [--sitekey KEY] [--proxy URL] [--verify SECRET] [--timeout S]

Prints the minted token to stdout. Build the solver first:
  cargo build --release --bin challenge
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BIN = ROOT / "target" / "release" / ("challenge.exe" if os.name == "nt" else "challenge")
PROFILE = ROOT / "profiles" / "chromium.json"
SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify"


def solve(url, sitekey=None, proxy=None, timeout=120):
    if not BIN.is_file():
        sys.exit(f"binary not found: {BIN}\nbuild first: cargo build --release --bin challenge")
    if not PROFILE.is_file():
        sys.exit(f"profile not found: {PROFILE}")
    out = tempfile.mkdtemp(prefix="cf-solve-")
    try:
        cmd = [str(BIN), "--page", url, out, "--solve", "--fingerprint", str(PROFILE)]
        if sitekey:
            cmd += ["--sitekey", sitekey]
        if proxy:
            cmd += ["--proxy", proxy]
        proc = subprocess.run(
            cmd, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=timeout,
        )
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
        token = lines[-1].strip() if lines else ""
        if proc.returncode != 0 or len(token) < 50:
            sys.exit(f"solve failed (exit {proc.returncode}); no token")
        if token.startswith("cf_clearance="):
            sys.stderr.write("note: cleared a challenge page (cf_clearance), not a widget token\n")
        return token
    except subprocess.TimeoutExpired:
        sys.exit(f"solve timed out after {timeout}s")
    finally:
        shutil.rmtree(out, ignore_errors=True)


def siteverify(token, secret):
    data = urllib.parse.urlencode({"secret": secret, "response": token}).encode()
    req = urllib.request.Request(SITEVERIFY, data=data)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main():
    ap = argparse.ArgumentParser(description="Browserless Turnstile solver (Chrome profile)")
    ap.add_argument("url", help="page URL embedding the Turnstile widget")
    ap.add_argument("--sitekey", help="select a widget by sitekey")
    ap.add_argument("--proxy", help="http/https/socks5/socks5h proxy URL")
    ap.add_argument("--verify", metavar="SECRET", help="siteverify secret to validate the token")
    ap.add_argument("--timeout", type=int, default=120, help="solve timeout seconds (default 120)")
    args = ap.parse_args()

    token = solve(args.url, args.sitekey, args.proxy, args.timeout)
    if args.verify:
        result = siteverify(token, args.verify)
        sys.stderr.write(json.dumps(result) + "\n")
        if not result.get("success"):
            sys.exit("siteverify failed")
    print(token)


if __name__ == "__main__":
    main()