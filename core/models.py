import os
import shutil
import tarfile
import requests
from tqdm import tqdm

MODELS = {
    "sensevoice": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2",
        "dir_name": "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
        "model_file": "model.int8.onnx",
        "tokens_file": "tokens.txt",
    },
    "paraformer": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-paraformer-zh-2024-03-09.tar.bz2",
        "dir_name": "sherpa-onnx-paraformer-zh-2024-03-09",
        "model_file": "model.int8.onnx",
        "tokens_file": "tokens.txt",
    },
    "whisper": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-large-v3.tar.bz2",
        "dir_name": "sherpa-onnx-whisper-large-v3",
        "encoder_file": "large-v3-encoder.int8.onnx",
        "decoder_file": "large-v3-decoder.int8.onnx",
        "tokens_file": "large-v3-tokens.txt",
    },
}

MODEL_DISPLAY_NAMES = {
    "sensevoice": "SenseVoice (zh/en/ja/ko, fast)",
    "paraformer": "Paraformer (zh/en bilingual)",
    "whisper": "Whisper large-v3 (99 languages, ~2GB)",
}


def _primary_file(info: dict) -> str:
    """Return the key file name used to check if a model is downloaded."""
    return info.get("encoder_file") or info["model_file"]


def is_model_downloaded(name: str, models_dir: str) -> bool:
    """Check if a model's files exist locally."""
    if name not in MODELS:
        return False
    info = MODELS[name]
    primary = os.path.join(models_dir, info["dir_name"], _primary_file(info))
    return os.path.exists(primary)


def delete_model_data(name: str, models_dir: str) -> None:
    """Delete a model's local files."""
    if name not in MODELS:
        return
    info = MODELS[name]
    model_dir = os.path.join(models_dir, info["dir_name"])
    if os.path.exists(model_dir):
        shutil.rmtree(model_dir)


def _download_file(url: str, dest: str, on_progress=None) -> None:
    """Download to a .part temp file, then atomically rename on success."""
    resp = requests.get(url, stream=True, timeout=30)
    resp.raise_for_status()
    total = int(resp.headers.get("content-length", 0))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    part_path = dest + ".part"
    downloaded = 0
    try:
        with open(part_path, "wb") as f, tqdm(
            total=total, unit="B", unit_scale=True, desc=os.path.basename(dest)
        ) as bar:
            for chunk in resp.iter_content(chunk_size=8192):
                f.write(chunk)
                bar.update(len(chunk))
                downloaded += len(chunk)
                if on_progress and total:
                    on_progress(downloaded, total)
        os.rename(part_path, dest)
    except BaseException:
        if os.path.exists(part_path):
            os.remove(part_path)
        raise


def ensure_model(name: str, models_dir: str, on_progress=None) -> dict:
    """Download model if not present. Returns dict with paths to model files.

    For standard models: {"model": ..., "tokens": ...}
    For Whisper models:  {"encoder": ..., "decoder": ..., "tokens": ...}
    """
    if name not in MODELS:
        supported = ", ".join(MODELS.keys())
        raise ValueError(
            f"Unknown model '{name}'. Supported models: {supported}"
        )
    info = MODELS[name]
    model_dir = os.path.join(models_dir, info["dir_name"])
    primary_path = os.path.join(model_dir, _primary_file(info))
    tokens_path = os.path.join(model_dir, info["tokens_file"])

    if not os.path.exists(primary_path):
        archive_path = os.path.join(models_dir, os.path.basename(info["url"]))
        if not os.path.exists(archive_path):
            print(f"Downloading {name} model...")
            _download_file(info["url"], archive_path, on_progress=on_progress)
        print(f"Extracting {name} model...")
        with tarfile.open(archive_path, "r:bz2") as tar:
            tar.extractall(path=models_dir, filter="data")
        os.remove(archive_path)

    if "encoder_file" in info:
        return {
            "encoder": os.path.join(model_dir, info["encoder_file"]),
            "decoder": os.path.join(model_dir, info["decoder_file"]),
            "tokens": tokens_path,
        }
    return {"model": primary_path, "tokens": tokens_path}


def ensure_all_models(models_dir: str, model_name: str = "sensevoice", on_progress=None) -> dict:
    """Ensure ASR model is downloaded. Returns paths."""
    os.makedirs(models_dir, exist_ok=True)
    return ensure_model(model_name, models_dir, on_progress=on_progress)
