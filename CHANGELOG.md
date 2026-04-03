# Changelog

## v1.1.0 — 2026-04-03

### New Features

- **Custom hotkey**: Change the dictation hotkey from the menu bar (`Change Hotkey...`). Uses the [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) library with built-in system shortcut conflict detection. Default: `Cmd+Shift+Space`.
- **Focus restore**: If you switch to another app during recording, TalkType automatically switches back to the original app before typing the transcription.
- **Always-on-top overlay**: The recording overlay now uses `.statusBar` window level, ensuring visibility above all normal windows including some fullscreen apps.

### Bug Fixes

- **Vocabulary hallucination fix**: Vocabulary hints are no longer sent to the Whisper API on low-volume audio, preventing the model from hallucinating vocab words on near-silent recordings.
- **Hotkey text corrected**: Menu and logs now correctly show `Cmd+Shift+Space` instead of `Option+Space`.

### Performance

- **KeyStorage caching**: Symmetric key is cached in memory — no longer spawns `/usr/sbin/ioreg` subprocess on every transcription.
- **AppIdentity.stateDir caching**: State directory path computed once at startup instead of checking the filesystem on every access.
- **Notification auth**: Permission requested once at startup instead of on every notification.

### Code Quality

- Thread safety: `VocabularyStore` entries protected with `NSLock`; `sessionID` reads moved to main thread; overlay audio level throttle moved to main thread.
- `transcriberLock` scope narrowed to prevent potential deadlock with delegate callbacks.
- Config propagation: model switch now calls `reloadConfig()` to sync all settings.
- Dead code removed: `AudioRecorder.ready`, unused `overlayPosition`/`overlayTheme` config fields.

## v1.0.0

Initial Swift release.
