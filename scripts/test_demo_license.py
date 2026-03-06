#!/usr/bin/env python3
"""End-to-end smoke test for Whisper-demo offline licensing."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from core.licensing import DEMO_PRODUCT, DemoLicenseManager


OPENSSL = "/opt/homebrew/bin/openssl"


def main() -> int:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        private_key = tmp / "private.pem"
        public_key = tmp / "public.pem"
        ledger = tmp / "issued.json"
        machine_id = "WHSPDEMO-TEST-0001"
        license_store = tmp / "installed.json"

        subprocess.run([OPENSSL, "genrsa", "-out", str(private_key), "2048"], check=True)
        subprocess.run([OPENSSL, "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)], check=True)

        license_path = tmp / "seat01.whisper-demo-license"
        subprocess.run(
            [
                str(ROOT / ".venv" / "bin" / "python3"),
                str(ROOT / "scripts" / "generate_demo_license.py"),
                "--seat-code",
                "seat01",
                "--machine-id",
                machine_id,
                "--name",
                "Test User",
                "--private-key",
                str(private_key),
                "--ledger",
                str(ledger),
                "--output",
                str(license_path),
            ],
            check=True,
            cwd=str(ROOT),
        )

        public_key_pem = public_key.read_text(encoding="utf-8")
        manager = DemoLicenseManager(
            license_path=license_store,
            public_key_pem=public_key_pem,
            machine_id_provider=lambda: machine_id,
            openssl_bin=OPENSSL,
        )
        imported = manager.import_license(license_path)
        assert imported["product"] == DEMO_PRODUCT
        assert manager.is_activated() is True
        assert "Activated" in manager.status_summary()[1]

        # Cross-machine reuse must fail.
        other_machine_manager = DemoLicenseManager(
            license_path=tmp / "other-installed.json",
            public_key_pem=public_key_pem,
            machine_id_provider=lambda: "WHSPDEMO-OTHER-9999",
            openssl_bin=OPENSSL,
        )
        try:
            other_machine_manager.import_license(license_path)
        except Exception:
            pass
        else:
            raise AssertionError("Expected cross-machine import to fail")

        # Seat ledger should refuse reuse to a different machine.
        result = subprocess.run(
            [
                str(ROOT / ".venv" / "bin" / "python3"),
                str(ROOT / "scripts" / "generate_demo_license.py"),
                "--seat-code",
                "seat01",
                "--machine-id",
                "WHSPDEMO-SECOND-0002",
                "--name",
                "Second User",
                "--private-key",
                str(private_key),
                "--ledger",
                str(ledger),
            ],
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert result.returncode != 0

        saved = json.loads(license_store.read_text(encoding="utf-8"))
        assert saved["seat_code"] == "seat01"

    print("demo-license-smoke-ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
