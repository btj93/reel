# Space-Switch Focus Suppression Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent macOS-initiated focus notifications from overriding the restored `activeColumnIndex` after a space switch.

**Architecture:** When switching spaces, macOS refocuses the previously-frontmost app's window on the destination space. This `kAXFocusedWindowChangedNotification` arrives asynchronously after our 150ms echo suppression window, overriding the restored focus. We add a 300ms space-switch-specific suppression for `.windowFocused` and `.appActivated` events. The timestamp is set inside `switchSpace()` at each exit point (after `applyLayout()` in the restored branch, after state clear in the new-space branch), keeping the invariant local to `StripController` and maximizing the effective post-completion suppression window.

**Tech Stack:** Swift, existing StripController/WindowManager modules

---

## File Map

- **Modify:** `Sources/WindowManager/StripController.swift` — add `lastSpaceSwitchTime` property, computed check, set timestamp inside `switchSpace()`
- **Modify:** `Sources/WindowManager/WindowManager.swift` — add suppression guard in `handleWindowEvent()`
- **Test:** `Tests/CoreTests/main.swift` — not applicable (timing/integration concern between macOS AX events and our event handler; no pure-logic to unit test)

---

### Task 1: Add space-switch suppression to StripController

**Files:**
- Modify: `Sources/WindowManager/StripController.swift:51-54` (property)
- Modify: `Sources/WindowManager/StripController.swift:761-764` (computed property)
- Modify: `Sources/WindowManager/StripController.swift:794-837` (switchSpace)

- [ ] **Step 1: Add the property and interval constant**

In `StripController`, after the existing `lastLayoutTime` / `echoSuppressionInterval` block (lines 51-54), add:

```swift
/// Timestamp of the last space switch. Used to suppress macOS-initiated
/// focus changes that arrive after echo suppression expires.
private var lastSpaceSwitchTime: Double = 0

/// How long to ignore focus events after a space switch (300ms).
/// macOS space-switch animations take ~250ms; focus notifications for the
/// previously-frontmost app arrive during or just after. 300ms gives margin.
public static let spaceSwitchFocusSuppressionInterval: Double = 0.3
```

Note: `lastSpaceSwitchTime` is `private` (not `public private(set)`) because it is only set inside `switchSpace()` — no external setter needed.

- [ ] **Step 2: Add the computed property**

Below the existing `isInEchoSuppression` computed property (lines 761-764), add:

```swift
/// True if we recently switched spaces and should ignore external focus changes.
public var isInSpaceSwitchSuppression: Bool {
    currentTime() - lastSpaceSwitchTime < Self.spaceSwitchFocusSuppressionInterval
}
```

- [ ] **Step 3: Set timestamp at both exit points of `switchSpace()`**

In `switchSpace(onScreenWindowIDs:)`, set the timestamp just before each `return`. This places it after `applyLayout()` in the restored branch and after the state clear in the new-space branch, maximizing effective post-completion suppression.

At line 823 (after `applyLayout()`), before `return true`, insert:

```swift
lastSpaceSwitchTime = currentTime()
```

At line 836 (after `focusRing.hide()`), before `return false`, insert:

```swift
lastSpaceSwitchTime = currentTime()
```

The method now reads:

```swift
public func switchSpace(onScreenWindowIDs: Set<UInt32>) -> Bool {
    // Save current space
    saveCurrentSpace()

    // Update fingerprint
    currentSpaceFingerprint = onScreenWindowIDs

    // Find best matching saved space (fuzzy: Jaccard similarity > 0.5)
    if let (matchedKey, saved) = findBestSavedSpace(for: onScreenWindowIDs) {
        // ... restore saved state (unchanged) ...

        applyLayout()
        lastSpaceSwitchTime = currentTime()
        return true
    }

    // New space — clear for fresh discovery
    // ... clear state (unchanged) ...
    focusRing.hide()
    lastSpaceSwitchTime = currentTime()
    return false
}
```

- [ ] **Step 4: Build to verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/WindowManager/StripController.swift
git commit -m "feat: add space-switch focus suppression timestamp to StripController"
```

---

### Task 2: Add suppression guard in WindowManager

**Files:**
- Modify: `Sources/WindowManager/WindowManager.swift:494-503` (handleWindowEvent)

- [ ] **Step 1: Add the guard in `handleWindowEvent()`**

In `handleWindowEvent()`, after the existing echo suppression block (lines 494-503, closing `}` on line 503), insert:

```swift
// Suppress focus events after a space switch — macOS refocuses
// the previously-frontmost app's window on the new space, which
// would override our restored activeColumnIndex.
if stripController.isInSpaceSwitchSuppression {
    switch event {
    case .windowFocused, .appActivated:
        print("[WM] Suppressed post-space-switch focus event")
        return
    default:
        break
    }
}
```

The full `handleWindowEvent` top now reads:

```swift
private func handleWindowEvent(_ event: WindowEvent) {
    // Ignore move/resize/focus events that echo from our own layout calls
    if stripController.isInEchoSuppression {
        switch event {
        case .windowResized, .windowMoved, .windowFocused, .appActivated:
            return
        default:
            break
        }
    }

    // Suppress focus events after a space switch — macOS refocuses
    // the previously-frontmost app's window on the new space, which
    // would override our restored activeColumnIndex.
    if stripController.isInSpaceSwitchSuppression {
        switch event {
        case .windowFocused, .appActivated:
            print("[WM] Suppressed post-space-switch focus event")
            return
        default:
            break
        }
    }

    switch event {
    // ... rest unchanged ...
```

- [ ] **Step 2: Build and verify**

Run: `swift build`
Expected: Compiles with no errors.

- [ ] **Step 3: Run tests**

Run: `swift run RunTests`
Expected: All existing tests pass (this change doesn't touch Core logic).

- [ ] **Step 4: Commit**

```bash
git add Sources/WindowManager/StripController.swift Sources/WindowManager/WindowManager.swift
git commit -m "fix: suppress macOS focus events after space switch

When switching spaces, macOS refocuses the previously-frontmost app's
window on the new space. This arrived after echo suppression expired,
overriding the restored activeColumnIndex. Add a 300ms space-switch-
specific suppression for focus/appActivated events."
```

---

### Task 3: Manual smoke test

- [ ] **Step 1: Build and launch**

Run: `swift build && .build/debug/ScrollWM &`

- [ ] **Step 2: Reproduce the original bug**

1. On Desktop 1, open an Arc window and a Terminal. Focus Terminal.
2. Switch to Desktop 2 where another Arc window exists. Focus Arc.
3. Switch back to Desktop 1.
4. Verify Terminal is still focused (not the Arc window on Desktop 1).
5. Check console output for `[WM] Suppressed post-space-switch focus event` — confirms the guard fired.

- [ ] **Step 3: Verify intentional focus still works**

After the space switch settles (>300ms), click on the Arc window on Desktop 1. Verify ScrollWM correctly scrolls to make it the active column. This confirms the suppression window isn't too long.

---

## Design Decisions

**Why 300ms?** macOS space-switch animations take ~250ms. Focus notifications for the previously-frontmost app arrive during or just after. 300ms gives comfortable margin without blocking intentional user focus changes.

**Why set the timestamp inside `switchSpace()`, not from `WindowManager`?** Follows the `applyLayout()` / `lastLayoutTime` pattern — the method that causes the timing concern owns the timestamp. Keeps `lastSpaceSwitchTime` fully private. Setting it at the exit points (after `applyLayout()` / state clear) maximizes effective post-completion suppression.

**Why not extend `isInEchoSuppression`?** Echo suppression blocks `.windowResized` and `.windowMoved` too. Extending it to 300ms would suppress legitimate user-initiated resize/move events. The space-switch suppression intentionally only blocks `.windowFocused` and `.appActivated`.

**Why not fix the "new space" branch's missing focus restoration?** That's a separate (less common) issue — it only occurs when Arc regenerates window IDs causing fingerprint match failure. The race condition described here happens even when fingerprint matching succeeds. Fix that separately if needed.
