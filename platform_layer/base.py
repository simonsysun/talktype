from abc import ABC, abstractmethod


class PlatformBase(ABC):
    """Abstract interface for platform-specific operations."""

    @abstractmethod
    def paste_text(self, text: str) -> None:
        """Copy text to clipboard and paste into focused app."""

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
    def set_launch_at_login(self, enabled: bool) -> None:
        """Enable or disable launch-at-login."""

    @abstractmethod
    def is_launch_at_login_enabled(self) -> bool:
        """Return whether launch-at-login is enabled."""

    @abstractmethod
    def run_on_main(self, fn) -> None:
        """Dispatch fn to the main/UI thread."""
