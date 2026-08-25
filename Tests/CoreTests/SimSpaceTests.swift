import AppKit
import CoreGraphics
import Foundation
import Core
import Platform
import WindowManager

// ============================================================
// MARK: - W4c — space stash/restore, scroll-mode, echo/space suppression,
//              boundary pairs (all on the virtual TestClock)
// ============================================================

private func fp(_ ids: UInt32...) -> Set<UInt32> { Set(ids) }

func runSimSpace() {
    print()
    print("StripController Simulation — space / scroll-mode / echo (W4c)")

    // ---- stash + restore roundtrip ----
    section("switchSpace stash + restore roundtrip")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceFingerprint(fp(1, 2))
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)  // wids 1, 2
        assertEq(sc.strip.columns.count, 2, "space A has 2 columns")

        let restoredB = sc.switchSpace(onScreenWindowIDs: fp(3, 4))
        check(!restoredB, "unknown space B → fresh (not restored)")
        assertEq(sc.strip.columns.count, 0, "fresh space clears strip")

        let restoredA = sc.switchSpace(onScreenWindowIDs: fp(1, 2))
        check(restoredA, "returning to A restores from stash")
        assertEq(sc.strip.columns.count, 2, "columns restored")
        check(sc.windowMap[ws[0].tileID] != nil && sc.windowMap[ws[1].tileID] != nil,
              "both windows restored into windowMap")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- LRU eviction ----
    section("savedSpaces LRU eviction past maxSavedSpaces (16)")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        for i in 1...17 {
            sc.setSpaceFingerprint(fp(UInt32(i)))
            clock.advance(1.0)              // distinct savedAt for deterministic LRU
            sc.saveCurrentSpace()
        }
        assertEq(sc.savedSpaceFingerprints.count, StripController.maxSavedSpaces,
                 "capped at maxSavedSpaces = 16")
        check(!sc.savedSpaceFingerprints.contains(fp(1)), "oldest (space 1) evicted")
        check(sc.savedSpaceFingerprints.contains(fp(17)), "newest (space 17) retained")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- pruneSavedSpaces: emptied snapshot deleted ----
    section("pruneSavedSpaces — emptied column deletes the snapshot")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceFingerprint(fp(100))
        let (_, ws) = addFakeWindows(sc, count: 1, width: 700)
        sc.saveCurrentSpace()
        check(sc.savedSpaceFingerprints.contains(fp(100)), "space stashed")
        sc.pruneSavedSpaces(removedTileID: ws[0].tileID)
        check(!sc.savedSpaceFingerprints.contains(fp(100)), "emptied snapshot removed")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- pruneSavedSpaces: multi-window snapshot survives; dead tile dropped ----
    section("pruneSavedSpaces — surviving window kept, pruned tile dropped")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceFingerprint(fp(200))
        let appA = FakeAXApp(pid: 92001, bundleIdentifier: "a")
        let appB = FakeAXApp(pid: 92002, bundleIdentifier: "b")
        let wa = FakeAXWindow(windowID: 20, pid: 92001, frame: CGRect(x: 0, y: 25, width: 700, height: 850))
        let wb = FakeAXWindow(windowID: 21, pid: 92002, frame: CGRect(x: 0, y: 25, width: 700, height: 850))
        sc.addWindow(wa, app: appA)
        sc.addWindow(wb, app: appB)
        sc.saveCurrentSpace()
        sc.pruneSavedSpaces(removedTileID: wa.tileID)
        check(sc.savedSpaceFingerprints.contains(fp(200)), "snapshot survives (still has a window)")
        let snap = sc.savedSpaceSnapshot(for: fp(200))
        check(snap != nil, "snapshot retrievable")
        check(!(snap?.contains { $0.tileID == wa.tileID } ?? true), "pruned tile dropped from stash")
        check(snap?.contains { $0.tileID == wb.tileID } ?? false, "other window retained")
        // (Dead-pid AXApp refs for pid 92001 are dropped internally; not directly observable.)
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- scroll mode: .center ----
    section("scrollToWindow .center — focuses, resets snapIndex, recenters")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.strip.snapPoints = [.left, .middle, .right]   // so a reset is observable
        let (_, ws) = addFakeWindows(sc, count: 3, width: 700)
        sc.strip.snapIndices[0] = 2                       // off default
        sc.scrollToWindow(tileID: ws[0].tileID, mode: .center)
        assertEq(sc.strip.activeColumnIndex, 0, ".center focuses the target column")
        assertEq(sc.strip.snapIndices[0], sc.strip.defaultSnapIndex, ".center resets snapIndex to default")
        assertClose(Double(ws[0].currentFrame.midX), 720, tolerance: 2, ".center recenters the target")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- scroll mode: .incrementalSnap ----
    section("scrollToWindow .incrementalSnap — slides to off-screen; no-ops when visible")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.strip.snapPoints = [.left, .middle, .right]
        let (_, ws) = addFakeWindows(sc, count: 3, width: 700)
        // Center col0 → col2 is off-screen to the right.
        sc.scrollToWindow(tileID: ws[0].tileID, mode: .center)
        // incrementalSnap to off-screen col2 → focus slides there.
        sc.scrollToWindow(tileID: ws[2].tileID, mode: .incrementalSnap)
        assertEq(sc.strip.activeColumnIndex, 2, "incrementalSnap slides focus to an off-screen col")

        // Now col2 active. incrementalSnap on a fully-visible active col is a scroll no-op.
        let viewPosBefore = sc.strip.viewPos(at: clock.t)
        sc.strip.snapIndices[2] = 0
        sc.scrollToWindow(tileID: ws[2].tileID, mode: .incrementalSnap)
        assertEq(sc.strip.activeColumnIndex, 2, "focus unchanged on visible target")
        assertClose(sc.strip.viewPos(at: clock.t), viewPosBefore, tolerance: 2, "no scroll for a visible target")
        assertEq(sc.strip.snapIndices[2], 0, "incrementalSnap does NOT reset snapIndex (contrast with .center)")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- echo suppression arming + boundary pair ----
    section("applyLayout arms lastLayoutTime; echo boundary 0.149 vs 0.151")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        addFakeWindows(sc, count: 1, width: 700)
        let t0 = clock.t
        sc.applyLayout()
        assertClose(sc.lastLayoutTime, t0, tolerance: 0.0001, "applyLayout arms lastLayoutTime = now")
        check(sc.isInEchoSuppression, "suppressed immediately after layout")
        clock.advance(0.149)
        check(sc.isInEchoSuppression, "0.149s < 0.15 → still suppressed")
        clock.advance(0.002)  // total 0.151
        check(!sc.isInEchoSuppression, "0.151s > 0.15 → suppression expired")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- #18 regression: settled ticks don't re-arm echo suppression ----
    section("finding #18 — a settled strip ticked repeatedly does NOT re-arm echo suppression")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC(animationEnabled: true)
        addFakeWindows(sc, count: 2, width: 700)
        sc.focusLeftAnimated(velocity: 0)
        settle(sc, clock)
        check(sc.isFullySettled, "animation settled")
        let armedAt = sc.lastLayoutTime
        // Keep ticking the fully-settled strip for ~1s of virtual time.
        for _ in 0..<60 { clock.advance(1.0 / 60.0); sc.handleFrameTick(time: clock.t) }
        assertClose(sc.lastLayoutTime, armedAt, tolerance: 0.0001,
                    "settled ticks do NOT bump lastLayoutTime (finding #18)")
        check(!sc.isInEchoSuppression, "suppression expires → genuine user moves aren't swallowed")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- space-switch suppression boundary pair ----
    section("space-switch focus suppression boundary 0.299 vs 0.301")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceFingerprint(fp(1))
        addFakeWindows(sc, count: 1, width: 700)
        _ = sc.switchSpace(onScreenWindowIDs: fp(5))  // arms lastSpaceSwitchTime = now
        check(sc.isInSpaceSwitchSuppression, "suppressed right after space switch")
        clock.advance(0.299)
        check(sc.isInSpaceSwitchSuppression, "0.299 < 0.3 → still suppressed")
        clock.advance(0.002)  // 0.301
        check(!sc.isInSpaceSwitchSuppression, "0.301 > 0.3 → expired")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // ---- confirmedUserActiveTileID boundary pair ----
    // A click-driven focus that has survived its debounce must be the column the
    // departing Space is stashed with. Before confirmUserActive existed,
    // _confirmedUserActiveTileID was written only by hotkey nav / addWindow /
    // space restore, so for a click-navigating user it stayed pinned to the
    // LAST-ADOPTED column — and because macOS fires a focus event just before
    // activeSpaceDidChange, saveCurrentSpace's 300ms distrust window always fell
    // back to that stale tile. Returning to the Space then focused the wrong
    // window (observed: 5-column strip restored onto col4/apidog while the user
    // was working in col3).
    section("saveCurrentSpace stashes the confirmed click column, not the last-adopted one")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceFingerprint(fp(1, 2, 3))
        let (_, ws) = addFakeWindows(sc, count: 3, width: 500)
        // Three adds → addWindow left _confirmed pinned to the last column (ws[2]).
        assertEq(sc.strip.activeColumnIndex, 2, "last adopted column is active")

        // User clicks column 1; the debounced scroll survives, so it is confirmed.
        clock.advance(5.0)
        sc.scrollToWindow(tileID: ws[1].tileID, mode: .incrementalSnap)
        sc.confirmUserActive(tileID: ws[1].tileID)
        assertEq(sc.strip.activeColumnIndex, 1, "click moved the active column")

        // macOS fires a focus event for that same window just BEFORE delivering
        // activeSpaceDidChange, arming the 300ms distrust window.
        sc.userActiveTileID = ws[1].tileID
        sc.userActiveTileIDTime = clock.t
        clock.advance(0.05)
        check(sc.confirmedUserActiveTileID == ws[1].tileID,
              "distrust fallback now names the clicked column, not the last-adopted one")

        // Leave to an unknown Space, then come back.
        check(!sc.switchSpace(onScreenWindowIDs: fp(9)), "unknown space → fresh")
        check(sc.switchSpace(onScreenWindowIDs: fp(1, 2, 3)), "returning restores the stash")
        assertEq(sc.strip.activeColumnIndex, 1,
                 "restored focus is the clicked column (was col2 before the fix)")
        check(sc.strip.activeColumn?.activeTile == ws[1].tileID, "and it maps to the clicked tile")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // Without a promotion, the stale fallback must still be what gets stashed —
    // this pins the pre-fix behavior so the guard's intent stays visible: a focus
    // event that a Space change cancels within the debounce is NOT trusted.
    section("an unconfirmed external focus inside the distrust window is still not stashed")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceFingerprint(fp(1, 2))
        let (_, ws) = addFakeWindows(sc, count: 2, width: 500)
        clock.advance(5.0)
        // Focus event arrives but the Space change cancels the debounce, so
        // confirmUserActive is never reached.
        sc.userActiveTileID = ws[0].tileID
        sc.userActiveTileIDTime = clock.t
        clock.advance(0.05)
        check(!sc.switchSpace(onScreenWindowIDs: fp(9)), "unknown space → fresh")
        check(sc.switchSpace(onScreenWindowIDs: fp(1, 2)), "returning restores")
        assertEq(sc.strip.activeColumnIndex, 1, "uncancelled artifact ignored; prior confirmed kept")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // With an authoritative id, a Space is looked up EXACTLY. Two Spaces whose
    // window sets overlap heavily — which Jaccard would happily merge — must stay
    // separate stashes.
    section("switchSpace — .skylight keys match exactly, never fuzzily")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceKey(.skylight(4), onScreenWindowIDs: fp(1, 2))
        let (_, ws) = addFakeWindows(sc, count: 2, width: 500)
        assertEq(sc.strip.columns.count, 2, "space sid=4 has 2 columns")

        check(!sc.switchSpace(to: .skylight(5), onScreenWindowIDs: fp(1, 2)),
              "a different sid is a different Space, even with identical windows")
        assertEq(sc.strip.columns.count, 0, "fresh Space starts empty")

        check(sc.switchSpace(to: .skylight(4), onScreenWindowIDs: fp(1, 2)),
              "returning to sid=4 restores exactly")
        assertEq(sc.strip.columns.count, 2, "columns restored")
        check(sc.windowMap[ws[0].tileID] != nil, "windows restored")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // The measured 414ms bounce, expressed in the new model.
    section("switchSpace — an A->B->A bounce restores the original stash")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceKey(.skylight(4), onScreenWindowIDs: fp(1, 2, 3))
        addFakeWindows(sc, count: 3, width: 400)
        sc.strip.activeColumnIndex = 1
        sc.confirmUserActive(tileID: sc.strip.columns[1].tiles[0])

        clock.advance(0.1)
        check(!sc.switchSpace(to: .skylight(5), onScreenWindowIDs: fp()), "left to sid=5")
        clock.advance(0.414)
        check(sc.switchSpace(to: .skylight(4), onScreenWindowIDs: fp(1, 2, 3)), "bounced back to sid=4")
        assertEq(sc.strip.columns.count, 3, "all columns back")
        assertEq(sc.strip.activeColumnIndex, 1, "focused column preserved across the bounce")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // The fingerprint keeps tracking the on-screen set even under an authoritative
    // key. It is the disk SnapshotKey discriminator and the input to the census
    // guards; letting it go empty would collapse every Space into one bucket.
    section("switchSpace — currentSpaceFingerprint still tracks on-screen IDs under a .skylight key")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceKey(.skylight(4), onScreenWindowIDs: fp(1, 2))
        assertEq(sc.currentSpaceFingerprint, fp(1, 2), "seeded fingerprint retained")
        _ = sc.switchSpace(to: .skylight(5), onScreenWindowIDs: fp(7, 8, 9))
        assertEq(sc.currentSpaceFingerprint, fp(7, 8, 9), "fingerprint follows the new Space")
        check(!sc.currentSpaceFingerprint.isEmpty, "never collapses to empty under an authoritative key")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // switchSpace must carry the persistent UUID, or every layout gets filed under
    // the PREVIOUS Space's UUID — and with exact-match disk lookups that silently
    // deletes the real owner's entry instead of self-correcting.
    section("switchSpace — carries the persistent Space UUID")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceKey(.skylight(4), onScreenWindowIDs: fp(1), spaceUUID: "UUID-A")
        assertEq(sc.currentSpaceUUID ?? "", "UUID-A", "seeded UUID retained")
        _ = sc.switchSpace(to: .skylight(5), onScreenWindowIDs: fp(2), spaceUUID: "UUID-B")
        assertEq(sc.currentSpaceUUID ?? "", "UUID-B", "UUID follows the Space, never lags")
        _ = sc.switchSpace(to: .fingerprint(fp(3)), onScreenWindowIDs: fp(3), spaceUUID: nil)
        check(sc.currentSpaceUUID == nil, "a Space with no UUID clears it rather than keeping the old one")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // savedSpaceFingerprints must report the fingerprint STORED IN each stash, not
    // one derived from the dictionary key. Deriving it returns [] under
    // authoritative keying, which silently disables spansMultipleSpaces — the only
    // defence against the observed 14-window cross-Space read — on the fallback
    // path that still needs it.
    section("savedSpaceFingerprints — reported from the stash, not the key")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceKey(.skylight(4), onScreenWindowIDs: fp(11, 12))
        addFakeWindows(sc, count: 1, width: 500)
        _ = sc.switchSpace(to: .skylight(5), onScreenWindowIDs: fp(21, 22))
        check(sc.savedSpaceFingerprints.contains(fp(11, 12)),
              "an authoritatively-keyed stash still reports its on-screen fingerprint")
        check(!sc.savedSpaceFingerprints.isEmpty, "never empty just because keys are authoritative")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    // A degraded episode (SkyLight briefly unavailable) must not orphan a stash.
    // Without this, a .fingerprint key can never match a .skylight stash: the strip
    // is wiped into fresh discovery, and the Space is re-keyed so an authoritative
    // return can never find it again.
    section("switchSpace — a fingerprint key can recover a .skylight stash and re-key it")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        sc.setSpaceKey(.skylight(4), onScreenWindowIDs: fp(1, 2, 3, 4))
        addFakeWindows(sc, count: 2, width: 500)
        _ = sc.switchSpace(to: .skylight(9), onScreenWindowIDs: fp(90))

        // SkyLight declines; we come back with only a fingerprint. 3 of 4 shared.
        check(sc.switchSpace(onScreenWindowIDs: fp(1, 2, 3, 99)),
              "degraded return still finds the stash by stored fingerprint")
        assertEq(sc.strip.columns.count, 2, "layout recovered, not rediscovered from scratch")

        // And the stash was re-keyed, so it is not orphaned under the old sid.
        _ = sc.switchSpace(to: .skylight(9), onScreenWindowIDs: fp(90))
        check(!sc.switchSpace(to: .skylight(4), onScreenWindowIDs: fp(1, 2, 3, 99)),
              "the old sid no longer holds a duplicate stash")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")

    section("confirmedUserActiveTileID boundary 0.299 vs 0.301")
    do {
        let clock = TestClock(100); clock.install(); defer { TimeUtil.nowProvider = nil }
        let sc = makeSC()
        let (_, ws) = addFakeWindows(sc, count: 2, width: 700)
        // Two adds → _confirmed = ws[1]. Now simulate a *recent external* focus to ws[0].
        sc.userActiveTileID = ws[0].tileID
        sc.userActiveTileIDTime = clock.t
        clock.advance(0.299)
        check(sc.confirmedUserActiveTileID == ws[1].tileID,
              "recent external focus (<0.3s) ignored → returns prior confirmed")
        clock.advance(0.002)  // 0.301 elapsed
        check(sc.confirmedUserActiveTileID == ws[0].tileID,
              "past 0.3s → external focus is confirmed")
    }
    check(TimeUtil.nowProvider == nil, "clock leaked out of section")
}
