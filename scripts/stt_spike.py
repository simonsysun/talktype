#!/usr/bin/env python3
"""Stage-0 STT spike: Doubao file flash vs xAI Grok REST (direct api.x.ai).

Product default stays Doubao. This script is research tooling only — it does not
change the app. Prefer direct xAI; do not use OpenRouter for product evidence.

Usage:
    # Grok only
    XAI_API_KEY=xai-... python3 scripts/stt_spike.py path/to/clip.wav

    # Doubao (env or macOS Keychain service talktype-doubao-api-key) + Grok
    XAI_API_KEY=xai-... python3 scripts/stt_spike.py \\
        --keyterm TalkType --keyterm 'Claude Code' \\
        source-materials/2026-08-03-asr-bakeoff/audio/*.wav

    # Arms: doubao, grok, grok_keyterms (default: all that have keys)
    python3 scripts/stt_spike.py --arms grok,grok_keyterms clip.wav

Env:
    XAI_API_KEY          required for Grok arms
    DOUBAO_API_KEY       optional; falls back to Keychain talktype-doubao-api-key
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

DOUBAO_ENDPOINT = (
    "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash"
)
DOUBAO_RESOURCE = "volc.bigasr.auc_turbo"
XAI_STT_ENDPOINT = "https://api.x.ai/v1/stt"
USER_AGENT = "TalkType-stt-spike/0.1"
KEYCHAIN_DOUBAO = "talktype-doubao-api-key"


def keychain_password(service: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["security", "find-generic-password", "-s", service, "-w"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    value = out.strip()
    return value or None


def clean_keyterms(terms: list[str]) -> list[str]:
    cleaned: list[str] = []
    for raw in terms:
        t = " ".join(raw.replace("\r", " ").replace("\n", " ").split()).strip()
        if not t:
            continue
        cleaned.append(t[:50])
        if len(cleaned) >= 100:
            break
    return cleaned


def doubao_hotword_context(terms: list[str]) -> str | None:
    clean = clean_keyterms(terms)
    if not clean:
        return None
    payload = {"hotwords": [{"word": w} for w in clean]}
    return json.dumps(payload, ensure_ascii=False)


def run_doubao(wav: bytes, api_key: str, terms: list[str], timeout: float) -> tuple[str, float]:
    request_fields: dict = {
        "model_name": "bigmodel",
        "enable_punc": True,
        "enable_itn": True,
        "enable_ddc": True,
    }
    ctx = doubao_hotword_context(terms)
    if ctx is not None:
        request_fields["corpus"] = {"context": ctx}

    body = {
        "user": {"uid": "talktype-spike"},
        "audio": {
            "data": base64.b64encode(wav).decode("ascii"),
            "format": "wav",
            "codec": "raw",
            "rate": 16000,
            "bits": 16,
            "channel": 1,
        },
        "request": request_fields,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(DOUBAO_ENDPOINT, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Api-Key", api_key)
    req.add_header("X-Api-Resource-Id", DOUBAO_RESOURCE)
    req.add_header("X-Api-Request-Id", str(uuid.uuid4()))
    req.add_header("X-Api-Sequence", "-1")
    req.add_header("User-Agent", USER_AGENT)

    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    elapsed = time.monotonic() - started
    parsed = json.loads(raw)
    if isinstance(parsed.get("result"), dict):
        text = (parsed["result"].get("text") or "").strip()
        if text:
            return text, elapsed
    message = parsed.get("message") or raw.decode("utf-8", errors="replace")[:300]
    raise RuntimeError(f"doubao rejected: {message}")


def _multipart(fields: list[tuple[str, str]], file_field: str, filename: str, file_bytes: bytes) -> tuple[bytes, str]:
    boundary = f"----TalkTypeSpike{uuid.uuid4().hex}"
    chunks: list[bytes] = []
    for name, value in fields:
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        chunks.append(value.encode("utf-8"))
        chunks.append(b"\r\n")
    # file last — xAI docs: options before file
    chunks.append(f"--{boundary}\r\n".encode())
    chunks.append(
        (
            f'Content-Disposition: form-data; name="{file_field}"; '
            f'filename="{filename}"\r\n'
            f"Content-Type: audio/wav\r\n\r\n"
        ).encode()
    )
    chunks.append(file_bytes)
    chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), boundary


def run_grok(
    wav: bytes,
    api_key: str,
    terms: list[str],
    timeout: float,
    *,
    use_keyterms: bool,
) -> tuple[str, float, dict]:
    fields: list[tuple[str, str]] = []
    # No format/language: Chinese is not in the official formatting list; do not pin en.
    if use_keyterms:
        for term in clean_keyterms(terms):
            fields.append(("keyterm", term))

    body, boundary = _multipart(fields, "file", "clip.wav", wav)
    req = urllib.request.Request(XAI_STT_ENDPOINT, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    req.add_header("User-Agent", USER_AGENT)

    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            headers = {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"grok HTTP {exc.code}: {detail}") from exc
    elapsed = time.monotonic() - started
    parsed = json.loads(raw)
    text = (parsed.get("text") or "").strip()
    if not text:
        raise RuntimeError(f"grok empty text: {parsed}")
    meta = {
        "language": parsed.get("language"),
        "duration": parsed.get("duration"),
        "zdr_header": headers.get("x-zero-data-retention"),
    }
    return text, elapsed, meta


def resolve_arms(requested: list[str] | None, has_doubao: bool, has_xai: bool) -> list[str]:
    default = []
    if has_doubao:
        default.append("doubao")
    if has_xai:
        default.extend(["grok", "grok_keyterms"])
    if not requested:
        return default
    unknown = [a for a in requested if a not in {"doubao", "grok", "grok_keyterms"}]
    if unknown:
        raise SystemExit(f"unknown arms: {unknown}")
    return requested


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("wavs", nargs="+", help="WAV files to transcribe")
    parser.add_argument("--keyterm", action="append", default=[], help="Vocabulary bias term (repeatable)")
    parser.add_argument("--keyterms-file", type=Path, help="One term per line")
    parser.add_argument(
        "--arms",
        default="",
        help="Comma list: doubao,grok,grok_keyterms (default: all with available keys)",
    )
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("source-materials/2026-08-09-grok-stt-spike/results"),
        help="JSON results directory (gitignored under source-materials/**/results/)",
    )
    args = parser.parse_args()

    terms = list(args.keyterm)
    if args.keyterms_file:
        for line in args.keyterms_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                terms.append(line)
    terms = clean_keyterms(terms)

    doubao_key = os.environ.get("DOUBAO_API_KEY") or keychain_password(KEYCHAIN_DOUBAO)
    xai_key = os.environ.get("XAI_API_KEY")

    requested = [a.strip() for a in args.arms.split(",") if a.strip()] or None
    try:
        arms = resolve_arms(requested, bool(doubao_key), bool(xai_key))
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2

    if not arms:
        print(
            "No arms available. Set XAI_API_KEY and/or DOUBAO_API_KEY "
            f"(or Keychain {KEYCHAIN_DOUBAO}).",
            file=sys.stderr,
        )
        return 1

    missing_for_request = []
    if requested:
        if "doubao" in requested and not doubao_key:
            missing_for_request.append("DOUBAO_API_KEY / Keychain")
        if any(a.startswith("grok") for a in requested) and not xai_key:
            missing_for_request.append("XAI_API_KEY")
    if missing_for_request:
        print(f"Missing credentials for requested arms: {', '.join(missing_for_request)}", file=sys.stderr)
        return 1

    print(f"arms={arms}")
    print(f"keyterms({len(terms)})={terms}")
    print(f"doubao_key={'yes' if doubao_key else 'no'} xai_key={'yes' if xai_key else 'no'}")

    runs: list[dict] = []
    for wav_path in args.wavs:
        wav = Path(wav_path)
        if not wav.exists():
            print(f"missing: {wav_path}", file=sys.stderr)
            continue
        audio = wav.read_bytes()
        print(f"\n=== {wav.name} ({len(audio) // 1024} KB) ===")

        for arm in arms:
            try:
                if arm == "doubao":
                    assert doubao_key
                    text, elapsed = run_doubao(audio, doubao_key, terms, args.timeout)
                    meta: dict = {}
                elif arm == "grok":
                    assert xai_key
                    text, elapsed, meta = run_grok(
                        audio, xai_key, terms, args.timeout, use_keyterms=False
                    )
                elif arm == "grok_keyterms":
                    assert xai_key
                    text, elapsed, meta = run_grok(
                        audio, xai_key, terms, args.timeout, use_keyterms=True
                    )
                else:
                    continue
            except Exception as exc:  # noqa: BLE001 — spike tooling; print and continue
                print(f"[{arm}] ERROR: {exc}")
                runs.append(
                    {
                        "clip": wav.name,
                        "arm": arm,
                        "ok": False,
                        "error": str(exc),
                        "keyterms": terms if arm.endswith("keyterms") or arm == "doubao" else [],
                    }
                )
                continue

            print(f"\n[{arm}] {elapsed:.2f}s\n  {text}")
            runs.append(
                {
                    "clip": wav.name,
                    "arm": arm,
                    "ok": True,
                    "latency_s": round(elapsed, 3),
                    "text": text,
                    "keyterms": terms if arm in {"doubao", "grok_keyterms"} else [],
                    "meta": meta,
                }
            )

    if not runs:
        return 1

    args.out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    out = args.out_dir / f"spike-{stamp}.json"
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "endpoint_xai": XAI_STT_ENDPOINT,
        "endpoint_doubao": DOUBAO_ENDPOINT,
        "note": "Stage-0 research only; not product truth. Direct xAI, no OpenRouter.",
        "runs": runs,
    }
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nResults: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
