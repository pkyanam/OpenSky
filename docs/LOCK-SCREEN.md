# Lock-screen behavior (design + parity)

Owner requirement: "computer use driver must run when the Mac is locked —
Codex Computer Use supports that. I want that experience working perfectly."

## What the reference implementation actually does (verified from its binary)
The ChatGPT.app native service contains a dedicated lock-screen subsystem:
`LockScreenMonitor`, `LockScreenController`, `LockScreenGuardian` (+ XPC
protocol `SAILockScreenGuardian{,Client}`), `LockScreenOverlayPresenter`,
`LockScreenPhysicalInputMonitor`, `LockScreenAutoUnlockCoordinator`
(+ `ExemptFromLockScreenAutoUnlock` request flag), plus a separate
`CUALockScreenGuardian.app` (LSUIElement) in SharedSupport.
It uses `CGSession*` keys (`kCGSSessionOnConsoleKey`, `kCGSSessionUserIDKey`,
`kCGSSessionSecureInputPID`) for console/lock state and Secure Input detection.

Read plainly: they do **not** synthesize input into the loginwindow. They
monitor lock state, **pause** UI automation while locked, present an overlay,
watch physical input (so the human's own typing at the lock screen is never
intercepted or confused), and **resume automatically on unlock**. Selected
requests can be exempted from auto-unlock gating. That is the correct and
only sane design — synthesizing keystrokes into a locked session's
loginwindow would require Secure-Input circumvention and is indistinguishable
from a keylogger.

## OpenSky v1 parity (same experience, public APIs only)
1. **LockScreenMonitor** — Darwin notifications
   (`com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`) +
   `CGSessionCopyCurrentDictionary` polling fallback (kCGSSessionOnConsoleKey).
2. **openskyd (LaunchAgent, RunAtLoad/KeepAlive)** — background service that
   survives lock/unlock and user switches; CLI/MCP clients enqueue work;
   queued input actions run the instant the session unlocks ("auto-resume").
3. **Guardian** — while locked: input synthesis is HARD-PAUSED (never inject
   while locked); listen-only CGEvent tap watches physical input to mark the
   queue "touched by human" (user can cancel); on unlock, a small overlay
   shows "OpenSky: 2 queued actions — resume / cancel" (LSUIElement window).
4. **Exempt requests** — `opensky ... --when-locked queue|fail|skip`
   (default `queue`): mirrors the reference's ExemptFromLockScreenAutoUnlock
   semantics without touching lock-screen input.

## What we deliberately do NOT do
- No input injection into the loginwindow (Secure Input exists; anything else
  is malware-shaped).
- No keylogging of the user's lock-screen typing — the physical-input monitor
  counts *events*, never records content.

This is 1:1 the observable behavior of the reference (works while locked =
survives, queues, guards, auto-resumes), implemented with zero private API.
