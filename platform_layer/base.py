from abc import ABC, abstractmethod


class PlatformBase(ABC):
    """Abstract interface for platform-specific operations."""

    @abstractmethod
    def paste_text(self, text: str) -> None:
        """Insert text into the focused app without changing the clipboard."""

    @abstractmethod
    def copy_text(self, text: str) -> None:
        """Copy text to clipboard only (no paste simulation)."""

    @abstractmethod
    def register_hotkey(self, on_dictation) -> None:
        """Register global hotkey handler for dictation."""

    @abstractmethod
    def request_accessibility(self) -> bool:
        """Request accessibility permission. Returns True if granted."""

    @abstractmethod
    def accessibility_granted(self, prompt: bool = False) -> bool:
        """Return whether accessibility permission is currently granted."""

    @abstractmethod
    def open_accessibility_settings(self) -> None:
        """Open system accessibility settings for the app."""

    @abstractmethod
    def set_launch_at_login(self, enabled: bool) -> None:
        """Enable or disable launch-at-login."""

    @abstractmethod
    def is_launch_at_login_enabled(self) -> bool:
        """Return whether launch-at-login is enabled."""

    @abstractmethod
    def run_on_main(self, fn) -> None:
        """Dispatch fn to the main/UI thread."""

    @abstractmethod
    def hotkey_capture_mode(self) -> str:
        """Return the currently active hotkey capture mode."""
