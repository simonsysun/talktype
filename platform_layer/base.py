from abc import ABC, abstractmethod


class PlatformBase(ABC):
    """Abstract interface for platform-specific operations."""

    @abstractmethod
    def paste_text(self, text: str) -> None:
        """Copy text to clipboard and paste into focused app."""

    def copy_text(self, text: str) -> None:
        """Copy text to clipboard only (no paste simulation)."""

    @abstractmethod
    def register_hotkey(self, on_dictation) -> None:
        """Register global hotkey handler for dictation."""

    @abstractmethod
    def request_accessibility(self) -> bool:
        """Request accessibility permission. Returns True if granted."""
