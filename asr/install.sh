#!/bin/bash
# Install the local ASR runtime into ~/.talktype/asr/.
#
# TalkType transcribes entirely on-device. This sets up what the app spawns at launch:
# a Python environment, the Qwen3-ASR weights, and server.py.
#
#   ./asr/install.sh              # 1.7B, the accuracy flagship (~3.8 GB)
#   ./asr/install.sh 0.6B         # smaller and faster, less accurate (~1.4 GB)
#
# Re-running is safe; it skips whatever is already in place.

set -euo pipefail

SIZE="${1:-1.7B}"
MODEL="mlx-community/Qwen3-ASR-${SIZE}-bf16"
DEST="$HOME/.talktype/asr"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing TalkType ASR runtime to $DEST"
echo "    model: $MODEL"

# qwen3-asr-mlx requires Python >=3.10,<3.14. A 3.14 system Python will not work.
if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required (brew install uv)" >&2
  exit 1
fi

mkdir -p "$DEST"

if [ ! -x "$DEST/venv/bin/python" ]; then
  echo "==> Creating Python 3.13 venv"
  uv venv --python 3.13 "$DEST/venv"
else
  echo "==> venv already present"
fi

echo "==> Installing qwen3-asr-mlx"
uv pip install --quiet --python "$DEST/venv/bin/python" qwen3-asr-mlx

echo "==> Downloading weights (skipped if already cached)"
HF_HOME="$DEST/hf" "$DEST/venv/bin/hf" download "$MODEL"

echo "==> Installing server.py"
cp "$SRC/server.py" "$DEST/server.py"

echo "==> Verifying"
HF_HOME="$DEST/hf" HF_HUB_OFFLINE=1 "$DEST/venv/bin/python" - <<'PY'
import os, sys
sys.path.insert(0, os.path.expanduser("~/.talktype/asr"))
import qwen3_asr_mlx  # noqa: F401
print("    qwen3-asr-mlx imports cleanly")
PY

cat <<EOF

Done. TalkType starts the engine itself — nothing to run by hand.

To run it manually (for debugging):
  HF_HOME=$DEST/hf HF_HUB_OFFLINE=1 $DEST/venv/bin/python $DEST/server.py

  GET  http://127.0.0.1:8756/health
  POST http://127.0.0.1:8756/transcribe   (raw WAV body)

Log: $DEST/server.log
EOF
