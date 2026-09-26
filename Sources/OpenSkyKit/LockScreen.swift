// OpenSky — LockScreen.swift (v2, cleaned)
// Lock-screen awareness and input gating (clean-room, public APIs only).
//
// Design (docs/LOCK-SCREEN.md): while the Mac is locked, input synthesis is
// HARD-PAUSED. Work enqueued during a lock is held and auto-resumed on
// unlock. We never inject input into the loginwindow and never record
// keystroke content — the physical-input monitor counts events only.

import AppKit
import Darwin
import notify

/// Observable lock-state monitor.
/// Primary source: Darwin notifications `com.apple.screenIsLocked/Unlocked`.
/// Fallback + initial state: `CGSessionCopyCurrentDictionary` →
/// `kCGSSessionOnConsoleKey`, plus loginwindow activation check.
public final class LockScreenMonitor: @unchecked Sendable {
    public static let shared = LockScreenMonitor()

    private let stateLock = NSLock()
    private var lockedState = false
    private var notifyTokens: [Int32] = []
    private var timer: Timer?

    /// Called on the main queue whenever lock state changes.
    public var onLockChange: ((Bool) -> Void)?

    private init() {
        lockedState = Self.probeLocked()
        registerObservers()
        startPollingFallback()
    }

    deinit {
        for token in notifyTokens { notify_cancel(token) }
        timer?.invalidate()
    }

    /// Thread-safe locked query.
    public var isLocked: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return lockedState
    }

    // MARK: sources

    /// Darwin notification registration with a context pointer (no closure
    /// capture restrictions).
    private func registerObservers() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        for literal in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            var token: Int32 = 0
            let status = literal.utf8CString.withUnsafeBufferPointer { buf -> Int32 in
                notify_register_dispatch(buf.baseAddress!, &token, DispatchQueue.main) { _ in
                    let monitor = Unmanaged<LockScreenMonitor>.fromOpaque(ctx).takeUnretainedValue()
                    monitor.refresh()
                }
                return token
            }
            if status != 0 { notifyTokens.append(status) }
        }
    }

    /// Polling fallback (2s) — covers notification loss across fast
    /// lock/unlock cycles and logind restarts.
    private func startPollingFallback() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    /// Refresh state from every source and notify on change.
    public func refresh() {
        let nowLocked = Self.probeLocked()
        stateLock.lock()
        let changed = nowLocked != lockedState
        lockedState = nowLocked
        stateLock.unlock()
        if changed {
            onLockChange?(nowLocked)
            LockInputGate.shared.setLocked(nowLocked)
        }
    }

    /// Public-API probe: is this session's console locked?
    static func probeLocked() -> Bool {
        // Source 1: CGSessionCopyCurrentDictionary — kCGSSessionOnConsoleKey
        // is false/absent when the console shows the loginwindow/lock UI.
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
           let onConsole = dict["kCGSSessionOnConsoleKey"] as? Bool {
            if !onConsole { return true }
        }
        // Source 2: the loginwindow app being active means the lock UI shows.
        if let login = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first,
           login.isActive {
            return true
        }
        return false
    }
}

/// Gates all input synthesis. While the session is locked, every mutating
/// action waits (or fails fast / skips, per the caller's `whenLocked` mode).
public final class LockInputGate: @unchecked Sendable {
    public static let shared = LockInputGate()

    public enum Mode: String, CaseIterable, Sendable {
        case queue   // default: hold until unlock, then run (auto-resume)
        case fail    // error immediately if locked
        case skip    // no-op with a "skipped-locked" outcome
    }

    public enum LockGateOutcome: Equatable, Sendable {
        case proceed
        case proceedAfterQueue
        case failedLocked
        case skippedLocked
    }

    private let gateLock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var touchedByHuman = false
    private var eventTap: CFMachPort?
    private var monitorInstalled = false

    init() {
        locked = LockScreenMonitor.probeLocked()
        installPhysicalInputMonitor()
        monitorInstalled = true
    }

    public var isLocked: Bool { gateLock.lock(); defer { gateLock.unlock() }; return locked }

    /// Called by the monitor on lock-state change.
    func setLocked(_ isLocked: Bool) {
        gateLock.lock()
        locked = isLocked
        let releaseWaiters = !isLocked ? waiters : []
        if !isLocked { waiters.removeAll() }
        gateLock.unlock()
        if !isLocked {
            // unlock: release every queued waiter (auto-resume)
            for w in releaseWaiters { w.resume() }
        } else {
            gateLock.lock(); touchedByHuman = false; gateLock.unlock()
        }
    }

    /// Gate an input action. Returns how the caller should proceed.
    /// `touchedByHuman` flips true if a physical key press arrives while work
    /// is parked (the user is present at the machine; agents should
    /// re-confirm). Counts events, records nothing.
    public func gate(_ mode: Mode) async -> LockGateOutcome {
        guard isLocked else { return .proceed }
        switch mode {
        case .fail: return .failedLocked
        case .skip: return .skippedLocked
        case .queue:
            await withCheckedContinuation { cont in
                gateLock.lock()
                if !locked { gateLock.unlock(); cont.resume(); return }
                waiters.append(cont)
                gateLock.unlock()
            }
            return .proceedAfterQueue
        }
    }

    /// Human-presence signal (event count only, no content).
    public var humanTouchedQueue: Bool { gateLock.lock(); defer { gateLock.unlock() }; return touchedByHuman }

    // MARK: physical-input monitor (listen-only CGEvent tap)

    private func installPhysicalInputMonitor() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let ctx = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, _, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let gate = Unmanaged<LockInputGate>.fromOpaque(refcon).takeUnretainedValue()
            if gate.isLocked { gate.noteHumanTouch() }
            return Unmanaged.passRetained(event)
        }, userInfo: ctx) else { return }
        eventTap = tap
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func noteHumanTouch() {
        gateLock.lock(); touchedByHuman = true; gateLock.unlock()
    }
}
