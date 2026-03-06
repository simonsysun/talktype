from __future__ import annotations

import base64
import hashlib
import json
import platform
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


DEMO_PRODUCT = "whisper-demo"
DEMO_LICENSE_PATH = Path.home() / ".whisper" / "demo-license.json"
DEMO_PUBLIC_KEY_PEM = """-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxln7Q3kbySH/KAJyT6LH
UMi1p/d5153L51edpy7/cF27hnHMCxhpBUUcuA2/MXN0/Mzjsds9tZj7tTpcGtoj
75Xv9RjQfsHbnPEfYcMZnT+Kdo6gPwDrJjzg+UzkhiUjRrbrPNG/iPoRCn6TqiFG
lczWIvmkJSLx40gRymFd7dWPVlJr7w9JilVivPPSlMZyX1ejqgzsGWaDrjEhgFzl
CSLV+CWl2l9sz4dWXPgeHdpc5a8yOK0n7QN34eHBjO5hWA6v0Xjkb1EDTecVWLlD
tQI1yoqfWOUcKlh4muHIjFpVH+9066i7MetL6fB3q0W/1n0jyIODBM3dBvdQh/SM
uQIDAQAB
-----END PUBLIC KEY-----
"""


class LicenseError(RuntimeError):
    pass


def is_demo_build() -> bool:
    try:
        import AppKit

        bundle = AppKit.NSBundle.mainBundle()
        bundle_id = bundle.bundleIdentifier() if bundle else ""
        if bundle_id and bundle_id.endswith(".demo"):
            return True
        name = bundle.objectForInfoDictionaryKey_("CFBundleName") if bundle else ""
        return bool(name and str(name).endswith("-demo"))
    except Exception:
        return False


def _openssl_bin() -> str:
    for candidate in ("/usr/bin/openssl", "/opt/homebrew/bin/openssl", "openssl"):
        resolved = shutil.which(candidate) if "/" not in candidate else candidate
        if resolved and Path(resolved).exists():
            return resolved
    raise LicenseError("OpenSSL is not available on this Mac.")


def _canonical_payload(data: dict) -> bytes:
    payload = {
        "version": int(data["version"]),
        "product": str(data["product"]),
        "seat_code": str(data["seat_code"]),
        "licensee": str(data["licensee"]),
        "machine_id": str(data["machine_id"]),
        "issued_at": str(data["issued_at"]),
    }
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _format_machine_hash(raw: str) -> str:
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest().upper()[:20]
    parts = [digest[i : i + 4] for i in range(0, len(digest), 4)]
    return "WHSPDEMO-" + "-".join(parts)


def default_machine_id() -> str:
    raw = None
    try:
        output = subprocess.check_output(
            ["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
            text=True,
            timeout=3.0,
        )
        match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', output)
        if match:
            raw = match.group(1).strip()
    except Exception:
        raw = None

    if not raw:
        raw = f"{platform.system()}::{platform.node()}"
    return _format_machine_hash(raw)


class DemoLicenseManager:
    def __init__(
        self,
        license_path: Path | None = None,
        public_key_pem: str = DEMO_PUBLIC_KEY_PEM,
        machine_id_provider=None,
        openssl_bin: str | None = None,
    ):
        self.license_path = license_path or DEMO_LICENSE_PATH
        self.public_key_pem = public_key_pem
        self.machine_id_provider = machine_id_provider or default_machine_id
        self.openssl_bin = openssl_bin or _openssl_bin()
        self._cached_license: dict | None = None
        self._cached_mtime_ns: int | None = None

    def machine_id(self) -> str:
        return str(self.machine_id_provider())

    def _verify_signature(self, payload: bytes, signature_b64: str) -> bool:
        try:
            signature = base64.b64decode(signature_b64, validate=True)
        except Exception as e:
            raise LicenseError(f"Invalid license signature encoding: {e}")

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            pub = tmp / "pub.pem"
            msg = tmp / "payload.bin"
            sig = tmp / "payload.sig"
            pub.write_text(self.public_key_pem, encoding="utf-8")
            msg.write_bytes(payload)
            sig.write_bytes(signature)
            result = subprocess.run(
                [
                    self.openssl_bin,
                    "dgst",
                    "-sha256",
                    "-verify",
                    str(pub),
                    "-signature",
                    str(sig),
                    str(msg),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        return result.returncode == 0

    def _validate_license_data(self, data: dict) -> dict:
        required = ("version", "product", "seat_code", "licensee", "machine_id", "issued_at", "signature")
        missing = [field for field in required if field not in data]
        if missing:
            raise LicenseError(f"License file is missing fields: {', '.join(missing)}")
        if str(data["product"]) != DEMO_PRODUCT:
            raise LicenseError("This license is not for Whisper-demo.")
        if str(data["machine_id"]) != self.machine_id():
            raise LicenseError("This license is for a different Mac.")

        payload = _canonical_payload(data)
        if not self._verify_signature(payload, str(data["signature"])):
            raise LicenseError("License signature verification failed.")
        return {
            "version": int(data["version"]),
            "product": str(data["product"]),
            "seat_code": str(data["seat_code"]),
            "licensee": str(data["licensee"]),
            "machine_id": str(data["machine_id"]),
            "issued_at": str(data["issued_at"]),
            "signature": str(data["signature"]),
        }

    def read_license_file(self, path: Path) -> dict:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise LicenseError("License file was not found.")
        except Exception as e:
            raise LicenseError(f"Failed to read license file: {e}")
        if not isinstance(data, dict):
            raise LicenseError("License file must be a JSON object.")
        return self._validate_license_data(data)

    def import_license(self, src_path: Path) -> dict:
        license_data = self.read_license_file(src_path)
        self.license_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.license_path.with_suffix(self.license_path.suffix + ".tmp")
        tmp.write_text(json.dumps(license_data, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(self.license_path)
        self._cached_license = dict(license_data)
        self._cached_mtime_ns = self.license_path.stat().st_mtime_ns
        return license_data

    def clear_license(self) -> bool:
        if self.license_path.exists():
            self.license_path.unlink()
            self._cached_license = None
            self._cached_mtime_ns = None
            return True
        return False

    def installed_license(self) -> dict | None:
        if not self.license_path.exists():
            self._cached_license = None
            self._cached_mtime_ns = None
            return None
        try:
            stat = self.license_path.stat()
        except OSError:
            self._cached_license = None
            self._cached_mtime_ns = None
            return None
        if self._cached_license is not None and self._cached_mtime_ns == stat.st_mtime_ns:
            return dict(self._cached_license)
        try:
            data = self.read_license_file(self.license_path)
            self._cached_license = dict(data)
            self._cached_mtime_ns = stat.st_mtime_ns
            return data
        except LicenseError as e:
            print(f"[license] installed license is invalid: {e}")
            self._cached_license = None
            self._cached_mtime_ns = None
            return None

    def is_activated(self) -> bool:
        return self.installed_license() is not None

    def status_summary(self) -> tuple[bool, str]:
        license_data = self.installed_license()
        if not license_data:
            return False, "Not activated"
        return True, f"Activated: {license_data['seat_code']} ({license_data['licensee']})"
