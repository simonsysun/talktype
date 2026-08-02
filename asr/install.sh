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

# uv supplies the Python runtime. qwen3-asr-mlx needs >=3.10,<3.14, and macOS ships
# nothing suitable — asking people to sort that out themselves is where an install stops
# being one step. uv's own installer needs no Homebrew and no admin rights.
UV=""
for candidate in uv "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
  if command -v "$candidate" >/dev/null 2>&1; then UV="$candidate"; break; fi
done

if [ -z "$UV" ]; then
  echo "==> Installing uv (Python environment manager)"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || {
    echo "error: could not install uv. Install it manually: https://docs.astral.sh/uv/" >&2
    exit 1
  }
  UV="$HOME/.local/bin/uv"
  [ -x "$UV" ] || { echo "error: uv installed but not found at $UV" >&2; exit 1; }
fi
echo "    uv: $UV"

mkdir -p "$DEST"

if [ ! -x "$DEST/venv/bin/python" ]; then
  echo "==> Creating Python 3.13 venv"
  "$UV" venv --python 3.13 "$DEST/venv"
else
  echo "==> venv already present"
fi

echo "==> Installing qwen3-asr-mlx"
"$UV" pip install --quiet --python "$DEST/venv/bin/python" qwen3-asr-mlx

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
