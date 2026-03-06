#!/usr/bin/env python3
"""Generate a machine-bound offline license for Whisper-demo."""

from __future__ import annotations

import argparse
import base64
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.licensing import DEMO_PRODUCT


DEFAULT_PRIVATE_KEY = REPO_ROOT / ".demo-license" / "demo_private_key.pem"
DEFAULT_ISSUED_LEDGER = REPO_ROOT / ".demo-license" / "issued_demo_licenses.json"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "dist" / "demo-licenses"


def canonical_payload(data: dict) -> bytes:
    payload = {
        "version": int(data["version"]),
        "product": str(data["product"]),
        "seat_code": str(data["seat_code"]),
        "licensee": str(data["licensee"]),
        "machine_id": str(data["machine_id"]),
        "issued_at": str(data["issued_at"]),
    }
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def openssl_bin() -> str:
    for candidate in ("/usr/bin/openssl", "/opt/homebrew/bin/openssl", "openssl"):
        resolved = shutil.which(candidate) if "/" not in candidate else candidate
        if resolved and Path(resolved).exists():
            return resolved
    raise RuntimeError("OpenSSL is required to generate licenses.")


def sign_payload(payload: bytes, private_key: Path) -> str:
    if not private_key.exists():
        raise RuntimeError(f"Private key not found: {private_key}")

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        payload_path = tmp / "payload.bin"
        sig_path = tmp / "payload.sig"
        payload_path.write_bytes(payload)
        subprocess.run(
            [
                openssl_bin(),
                "dgst",
                "-sha256",
                "-sign",
                str(private_key),
                "-out",
                str(sig_path),
                str(payload_path),
            ],
            check=True,
        )
        return base64.b64encode(sig_path.read_bytes()).decode("ascii")


def load_issued_ledger(path: Path) -> dict:
    if not path.exists():
        return {"issued": {}}
    return json.loads(path.read_text(encoding="utf-8"))


def save_issued_ledger(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a machine-bound Whisper-demo license")
    parser.add_argument("--seat-code", required=True, help="One of your demo seat codes")
    parser.add_argument("--machine-id", required=True, help="Machine ID shown inside Whisper-demo")
    parser.add_argument("--name", required=True, help="Licensee / friend name")
    parser.add_argument(
        "--private-key",
        default=str(DEFAULT_PRIVATE_KEY),
        help=f"Private signing key path (default: {DEFAULT_PRIVATE_KEY})",
    )
    parser.add_argument(
        "--ledger",
        default=str(DEFAULT_ISSUED_LEDGER),
        help=f"Issued seat ledger path (default: {DEFAULT_ISSUED_LEDGER})",
    )
    parser.add_argument(
        "--output",
        default="",
        help="Output file path; defaults to dist/demo-licenses/<seat>.whisper-demo-license",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Allow reissuing an already-used seat code to a new machine",
    )
    args = parser.parse_args()

    private_key = Path(args.private_key).expanduser().resolve()
    ledger_path = Path(args.ledger).expanduser().resolve()

    seat_code = args.seat_code.strip()
    machine_id = args.machine_id.strip()
    licensee = args.name.strip()
    if not seat_code or not machine_id or not licensee:
        raise SystemExit("seat-code, machine-id, and name must be non-empty")

    ledger = load_issued_ledger(ledger_path)
    issued = ledger.setdefault("issued", {})
    existing = issued.get(seat_code)
    if existing and existing.get("machine_id") != machine_id and not args.force:
        raise SystemExit(
            f"Seat code {seat_code} is already assigned to machine {existing.get('machine_id')}. "
            "Use --force to override."
        )

    payload = {
        "version": 1,
        "product": DEMO_PRODUCT,
        "seat_code": seat_code,
        "licensee": licensee,
        "machine_id": machine_id,
        "issued_at": datetime.now(timezone.utc).isoformat(),
    }
    payload["signature"] = sign_payload(canonical_payload(payload), private_key)

    if args.output:
        output_path = Path(args.output).expanduser().resolve()
    else:
        DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        safe_name = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in licensee).strip("_") or "licensee"
        output_path = DEFAULT_OUTPUT_DIR / f"{seat_code}-{safe_name}.whisper-demo-license"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    issued[seat_code] = {
        "licensee": licensee,
        "machine_id": machine_id,
        "issued_at": payload["issued_at"],
        "output": str(output_path),
    }
    save_issued_ledger(ledger_path, ledger)

    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
