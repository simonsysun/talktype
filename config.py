import os
import yaml

DEFAULT_CONFIG = {
    "dictation_hotkey": "option+space",
    "sample_rate": 16000,
    "overlay_position": "center-bottom",
    "overlay_theme": "auto",
    "launch_at_login": False,
    "asr_model": "gpt-4o-mini-transcribe",
    "asr_timeout_seconds": 30.0,
}

CONFIG_PATH = os.path.expanduser("~/.whisper/config.yaml")


def load_config() -> dict:
    try:
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH) as f:
                user = yaml.safe_load(f) or {}
            merged = {**DEFAULT_CONFIG, **user}
        else:
            merged = dict(DEFAULT_CONFIG)
    except yaml.YAMLError as e:
        print(f"Warning: config file is corrupted ({e}), using defaults.")
        merged = dict(DEFAULT_CONFIG)
    # Force sample rate to 16kHz — required by ASR model
    merged["sample_rate"] = 16000
    return merged


def save_config(cfg: dict) -> None:
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(cfg, f, default_flow_style=False)
