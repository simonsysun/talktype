"""macOS Keychain wrapper for secure API key storage via pyobjc-framework-Security."""

import Security


_SERVICE = "com.whisper.api-keys"


def store_key(provider: str, api_key: str) -> bool:
    """Store an API key in the macOS Keychain. Overwrites if exists."""
    # Try to delete existing entry first (ignore errors)
    delete_key(provider)

    attrs = {
        Security.kSecClass: Security.kSecClassGenericPassword,
        Security.kSecAttrService: _SERVICE,
        Security.kSecAttrAccount: provider,
        Security.kSecValueData: api_key.encode("utf-8"),
    }
    status = Security.SecItemAdd(attrs, None)
    return status == 0  # errSecSuccess


def retrieve_key(provider: str) -> str | None:
    """Retrieve an API key from the macOS Keychain."""
    query = {
        Security.kSecClass: Security.kSecClassGenericPassword,
        Security.kSecAttrService: _SERVICE,
        Security.kSecAttrAccount: provider,
        Security.kSecReturnData: True,
        Security.kSecMatchLimit: Security.kSecMatchLimitOne,
    }
    status, result = Security.SecItemCopyMatching(query, None)
    if status != 0 or result is None:
        return None
    # result is NSData / CFData — convert to bytes then str
    return bytes(result).decode("utf-8")


def delete_key(provider: str) -> bool:
    """Delete an API key from the macOS Keychain."""
    query = {
        Security.kSecClass: Security.kSecClassGenericPassword,
        Security.kSecAttrService: _SERVICE,
        Security.kSecAttrAccount: provider,
    }
    status = Security.SecItemDelete(query)
    return status == 0
