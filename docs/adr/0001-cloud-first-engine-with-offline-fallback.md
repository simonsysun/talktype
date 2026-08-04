# Cloud-first engine with offline fallback

TalkType's speech engine is cloud-first: a dictation uses the Cloud Engine whenever it is
reachable, and automatically falls back to the Local Engine when it is not, notifying the
user on every switch. This replaces the 2026-08-02 "chosen engine, no fallback" decision in
TODO.md: the user prioritises saving the ~4 GB resident memory over output predictability,
and the switch notification keeps the user informed of which engine actually ran.

Status: accepted (2026-08-03)

Considered Options:
- Cloud only, no fallback — rejected: no dictation offline.
- Local default, cloud optional — rejected: does not save memory by default.
- Cloud-first, fallback with notification — chosen: saves memory by default and still works
  offline; the notification makes the switch visible.

Consequences:
- Memory: ~0 extra (cloud) normally; ~4 GB only while the Local Engine is actually running.
- Privacy: audio leaves the machine by default; offline dictations stay local.
- Predictability: each dictation may come from a different engine; the switch notification
  and the menu bar state are how the user can tell.
