#!/usr/bin/env python3
"""TalkType cloud-ASR bake-off.

Runs the same WAV files through every candidate engine and prints latency + transcript
per clip, so accuracy can be compared by ear (there is no ground truth yet).

Usage:
    OPENROUTER_API_KEY=sk-or-... python3 scripts/bakeoff.py docs/bakeoff/audio/clip1.wav ...
    DASHSCOPE_API_KEY=sk-... python3 scripts/bakeoff.py docs/bakeoff/audio/*.wav

OpenRouter (one key, all candidates):
    qwen/qwen3-asr-flash-2026-02-10      recommended cloud engine
    openai/gpt-4o-transcribe             comparison arm
    openai/gpt-4o-mini-transcribe        cheap comparison arm
DashScope (optional, official Qwen3-ASR-Flash): needs its own key; exercises the
    Chinese-region path (Beijing/Singapore) end to end.

Output is a table plus a JSON dump in bakeoff-results/ for diffing later.
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path

OPENROUTER_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
DASHSCOPE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"

OPENROUTER_MODELS = [
    "qwen/qwen3-asr-flash-2026-02-10",
    "openai/gpt-4o-transcribe",
    "openai/gpt-4o-mini-transcribe",
]
DASHSCOPE_MODEL = "qwen3-asr-flash"


def post(url, payload, api_key):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "TalkType-bakeoff/1.0")
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read()
    elapsed = time.monotonic() - started
    return json.loads(body), elapsed


def run_openrouter(wav_bytes, model, api_key):
    payload = {
        "model": model,
        "input_audio": {
            "data": base64.b64encode(wav_bytes).decode("ascii"),
            "format": "wav",
        },
    }
    result, elapsed = post(OPENROUTER_URL, payload, api_key)
    return result.get("text", "").strip(), elapsed


def run_dashscope(wav_bytes, api_key):
    data_uri = "data:audio/wav;base64," + base64.b64encode(wav_bytes).decode("ascii")
    payload = {
        "model": DASHSCOPE_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "input_audio", "input_audio": {"data": data_uri}},
                ],
            }
        ],
        "asr_options": {"enable_itn": True},
    }
    result, elapsed = post(DASHSCOPE_URL, payload, api_key)
    try:
        text = result["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, TypeError):
        text = f"<unparsed: {result}>"
    return text, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wavs", nargs="+", help="WAV files to transcribe")
    args = parser.parse_args()

    openrouter_key = os.environ.get("OPENROUTER_API_KEY")
    dashscope_key = os.environ.get("DASHSCOPE_API_KEY")
    if not openrouter_key and not dashscope_key:
        print("Set OPENROUTER_API_KEY and/or DASHSCOPE_API_KEY first.", file=sys.stderr)
        sys.exit(1)

    runs = []
    for wav_path in args.wavs:
        wav = Path(wav_path)
        if not wav.exists():
            print(f"missing: {wav_path}", file=sys.stderr)
            continue
        print(f"\n=== {wav.name} ({wav.stat().st_size // 1024} KB) ===")
        for model in OPENROUTER_MODELS:
            if not openrouter_key:
                continue
            try:
                text, elapsed = run_openrouter(wav.read_bytes(), model, openrouter_key)
            except Exception as exc:  # noqa: BLE001
                print(f"[{model}] ERROR: {exc}")
                continue
            print(f"\n[{model}] {elapsed:.2f}s\n  {text}")
            runs.append({"clip": wav.name, "engine": model, "latency_s": elapsed, "text": text})

        if dashscope_key:
            try:
                text, elapsed = run_dashscope(wav.read_bytes(), dashscope_key)
            except Exception as exc:  # noqa: BLE001
                print(f"[{DASHSCOPE_MODEL}] ERROR: {exc}")
                continue
            print(f"\n[{DASHSCOPE_MODEL} (DashScope)] {elapsed:.2f}s\n  {text}")
            runs.append({"clip": wav.name, "engine": f"{DASHSCOPE_MODEL} (DashScope)", "latency_s": elapsed, "text": text})

    if runs:
        out_dir = Path("bakeoff-results")
        out_dir.mkdir(exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        out = out_dir / f"bakeoff-{stamp}.json"
        out.write_text(json.dumps(runs, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nResults: {out}")


if __name__ == "__main__":
    main()
