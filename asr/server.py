#!/usr/bin/env python3
"""TalkType local ASR sidecar — Qwen3-ASR on Apple Silicon via MLX.

The Swift app spawns this at launch and POSTs raw WAV bytes to it. Weights load
once and stay resident, so every dictation after startup is a warm inference.

Protocol (deliberately minimal — no multipart, no auth, loopback only):

  GET  /health          -> 200 {"status":"ready","model":...}  once weights are loaded
                           503 {"status":"loading"}            while they load
  POST /transcribe      -> 200 {"text":...,"seconds":...}
       body:              raw WAV bytes (16 kHz mono is what TalkType records)
       X-TalkType-Context: optional comma-separated vocabulary terms

Inference runs on ONE dedicated thread — the same one that loaded the weights.
MLX's Metal stream is thread-local, so calling transcribe() from an HTTP handler
thread fails with "There is no Stream(gpu, 0) in current thread". Handlers submit
jobs to a queue instead; this also serialises inference, which the model requires
anyway, while leaving /health answerable during a long transcription.

Vocabulary MUST stay a bare comma list. Prose context makes the model complete the
prompt instead of transcribing — it translated a Chinese clip into English and
invented a sentence that was never spoken. Same failure the macOS app's
PostProcessor.isLikelyHallucination was written to catch on Whisper.

Language is auto-detected. Pinning zh gave marginally better punctuation on a
Chinese-primary sample, but the speaker also dictates English-primary. Pinning does
not corrupt the other language — a zh-pinned English clip transcribed perfectly —
it only nudges punctuation conventions. --language stays available as an override.
"""

import argparse
import gc
import json
import os
import queue
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_MODEL = "mlx-community/Qwen3-ASR-1.7B-bf16"
DEFAULT_PORT = 8756
MAX_BODY = 64 * 1024 * 1024          # 64 MB — ~30 min of 16 kHz mono
MAX_CONTEXT = 800                    # matches VocabularyStore's prompt budget
JOB_TIMEOUT = 300                    # seconds a handler will wait for inference
IDLE_UNLOAD_SECONDS = 300            # release ~2.4 GB after this long with no work

_ready = threading.Event()
_jobs: "queue.Queue" = queue.Queue()

MODEL_ID = DEFAULT_MODEL
LANGUAGE = None                      # None = auto-detect
TMP_DIR = tempfile.gettempdir()


def log(msg):
    print(f"[asr] {msg}", flush=True)


def watch_parent():
    """Exit when the app that spawned us goes away.

    The app hands us a pipe as stdin and holds the write end open. Any way the parent
    dies — clean quit, SIGTERM, SIGKILL, crash — the pipe closes and the read returns
    EOF. Relying on the app to terminate us instead would leak a multi-GB process every
    time it did not exit cleanly.

    Only the app asks for this, via --watch-parent. Run by hand and backgrounded, stdin
    is closed immediately, which the watchdog cannot tell apart from the app dying — the
    server would exit the moment it started.
    """
    try:
        sys.stdin.read()
    except Exception:                                 # noqa: BLE001
        pass
    log("parent exited — shutting down")
    os._exit(0)


def inference_worker():
    """Owns the model for the process lifetime. Never let this thread die.

    Loading, inference and unloading all happen here because MLX's Metal stream is
    thread-local. After IDLE_UNLOAD_SECONDS with no work the weights are released,
    which returns about 2.4 GB; the next dictation pays ~0.25 s to load them back.
    """
    import mlx.core as mx
    from qwen3_asr_mlx import Qwen3ASR

    model = None

    def ensure_loaded():
        nonlocal model
        if model is None:
            t = time.time()
            model = Qwen3ASR.from_pretrained(MODEL_ID)
            log(f"model loaded in {time.time() - t:.2f}s: {MODEL_ID}")
        return model

    ensure_loaded()
    _ready.set()                                       # ready stays set across unloads

    while True:
        try:
            # Block forever when already unloaded; there is nothing left to reclaim.
            job = _jobs.get(timeout=IDLE_UNLOAD_SECONDS) if model else _jobs.get()
        except queue.Empty:
            model.close()
            model = None
            gc.collect()
            log(f"idle {IDLE_UNLOAD_SECONDS}s — released model weights")
            continue

        if job is None:
            return
        path, context, box, done = job
        try:
            started = time.time()
            result = ensure_loaded().transcribe(path, language=LANGUAGE, context=context)
            text = getattr(result, "text", None)
            box["text"] = (text if text is not None else str(result)).strip()
            box["seconds"] = round(time.time() - started, 3)
            # Hand MLX's scratch buffers back after every job. Without this the process
            # grew about 1 MB per transcription — invisible in a short test, ~200 MB over
            # a heavy day. Costs well under a millisecond; the weights are untouched.
            mx.clear_cache()
        except Exception as exc:                      # noqa: BLE001 - report, don't die
            box["error"] = f"{type(exc).__name__}: {exc}"
        finally:
            done.set()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass                          # the app owns the log; skip per-request noise

    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            return self._send(404, {"error": "not found"})
        ready = _ready.is_set()
        self._send(200 if ready else 503,
                   {"status": "ready" if ready else "loading", "model": MODEL_ID})

    def do_POST(self):
        if self.path != "/transcribe":
            return self._send(404, {"error": "not found"})
        if not _ready.is_set():
            return self._send(503, {"error": "model still loading"})

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return self._send(400, {"error": "bad Content-Length"})
        if length <= 0:
            return self._send(400, {"error": "empty body"})
        if length > MAX_BODY:
            return self._send(413, {"error": f"body over {MAX_BODY} bytes"})

        audio = self.rfile.read(length)
        if len(audio) != length:
            return self._send(400, {"error": "truncated body"})

        context = self.headers.get("X-TalkType-Context") or None
        if context:
            context = context.strip()[:MAX_CONTEXT] or None

        # qwen3-asr-mlx reads from a path, so the bytes have to land on disk.
        fd, path = tempfile.mkstemp(suffix=".wav", dir=TMP_DIR)
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(audio)

            box, done = {}, threading.Event()
            _jobs.put((path, context, box, done))
            if not done.wait(JOB_TIMEOUT):
                return self._send(504, {"error": "inference timed out"})

            if "error" in box:
                log(f"ERROR {box['error']}")
                return self._send(500, {"error": box["error"]})

            log(f"transcribed {len(audio)} bytes in {box['seconds']}s")
            self._send(200, {"text": box["text"], "seconds": box["seconds"]})
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass


def main():
    global MODEL_ID, LANGUAGE, TMP_DIR, IDLE_UNLOAD_SECONDS
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("TALKTYPE_ASR_MODEL", DEFAULT_MODEL))
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("TALKTYPE_ASR_PORT", DEFAULT_PORT)))
    ap.add_argument("--language", default=os.environ.get("TALKTYPE_ASR_LANGUAGE") or None,
                    help="ISO code to pin (e.g. zh, en). Omit to auto-detect.")
    ap.add_argument("--idle-unload", type=float, default=IDLE_UNLOAD_SECONDS,
                    help="seconds of inactivity before releasing weights; 0 disables")
    ap.add_argument("--watch-parent", action="store_true",
                    help="exit when stdin closes; the app passes this so we die with it")
    ap.add_argument("--tmp-dir", default=os.environ.get("TMPDIR", tempfile.gettempdir()))
    args = ap.parse_args()

    MODEL_ID = args.model
    LANGUAGE = args.language
    TMP_DIR = args.tmp_dir
    IDLE_UNLOAD_SECONDS = args.idle_unload or None
    os.makedirs(TMP_DIR, exist_ok=True)

    # Bind before loading weights so the app can connect immediately and poll
    # /health rather than racing a multi-second startup.
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    log(f"listening on 127.0.0.1:{args.port}  language={LANGUAGE or 'auto'}")

    threading.Thread(target=inference_worker, daemon=True).start()
    if args.watch_parent:
        threading.Thread(target=watch_parent, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
