import os
import yaml

from core.app_identity import state_dir

DEFAULT_CONFIG = {
    "dictation_hotkey": "option+space",
    "sample_rate": 16000,
    "overlay_position": "center-bottom",
    "overlay_theme": "auto",
    "launch_at_login": False,
    "asr_model": "gpt-4o-mini-transcribe",
    "asr_timeout_seconds": 30.0,
    "silence_auto_stop_enabled": True,
    "silence_auto_stop_seconds": 20,
    "silence_rms_threshold": 0.008,
    "min_transcribe_rms": 0.003,
}


def config_path() -> str:
    return str(state_dir() / "config.yaml")


def load_config() -> dict:
    path = config_path()
    try:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                user = yaml.safe_load(f)
            if user is None:
                user = {}
            elif not isinstance(user, dict):
                raise ValueError("config root must be a mapping")
            merged = {**DEFAULT_CONFIG, **user}
        else:
            merged = dict(DEFAULT_CONFIG)
    except (OSError, TypeError, ValueError, yaml.YAMLError) as e:
        print(f"Warning: config file is corrupted ({e}), using defaults.")
        merged = dict(DEFAULT_CONFIG)
    # Force sample rate to 16kHz — required by ASR model
    merged["sample_rate"] = 16000
    return merged


def save_config(cfg: dict) -> None:
    path = config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
    os.replace(tmp, path)
