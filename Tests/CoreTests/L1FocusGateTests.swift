import Foundation
import Core

// FocusEventGate coverage (W11 — WindowManager-owned dock-activation carryover).
//
// Semantics under test (must match the extracted WindowManager logic exactly):
//   - recordAppActivation(pid:at:) stamps (pid, time); newest wins (overwrite).
//   - consumeRecentActivation(at:) is one-shot: returns the pid iff a record
//     exists AND `t - recordedTime < 0.5` (strict); ALWAYS clears the record.
//   - A second consume (this turn or later) returns nil.
//
// pid_t is Int32; test pids are arbitrary positive values.

func runL1FocusGateTests() {
    print()
    print("FocusEventGate Tests")

    section("TTL constant is 0.5s (matches historical appActivationCarryover)")
    do {
        assertClose(FocusEventGate.appActivationCarryover, 0.5, tolerance: 1e-12, "TTL")
    }

    section("no record → consume returns nil")
    do {
        var gate = FocusEventGate()
        check(gate.consumeRecentActivation(at: 1000) == nil, "empty gate yields nil")
    }

    section("record then immediate consume returns the pid")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 4242, at: 1000)
        assertEq(gate.consumeRecentActivation(at: 1000), pid_t(4242), "same-instant consume")
    }

    // TTL boundary pair. Strict `<`: 0.499 is inside (returns pid), 0.501 is
    // outside (returns nil). 0.5 exactly is NOT < 0.5 → nil (also checked).
    section("TTL boundary — 0.499 inside, returns pid")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 7, at: 1000)
        assertEq(gate.consumeRecentActivation(at: 1000.499), pid_t(7), "0.499 < 0.5 → live")
    }

    section("TTL boundary — 0.501 expired, returns nil")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 7, at: 1000)
        check(gate.consumeRecentActivation(at: 1000.501) == nil, "0.501 ≥ 0.5 → expired")
    }

    section("TTL boundary — exactly 0.5 is expired (strict <)")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 7, at: 1000)
        check(gate.consumeRecentActivation(at: 1000.5) == nil, "0.5 is NOT < 0.5 → expired")
    }

    section("consume-once — second consume returns nil (one-shot)")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 99, at: 1000)
        assertEq(gate.consumeRecentActivation(at: 1000.1), pid_t(99), "first consume live")
        check(gate.consumeRecentActivation(at: 1000.1) == nil, "second consume nil (cleared)")
    }

    // "consume regardless" — even an expired consume clears the record, so a
    // subsequent in-TTL consume (were the record still there) also yields nil.
    section("expired consume still clears the record")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 5, at: 1000)
        check(gate.consumeRecentActivation(at: 2000) == nil, "expired → nil")
        // Even querying back inside the original TTL yields nil: it was cleared.
        check(gate.consumeRecentActivation(at: 1000.1) == nil, "record was cleared on expired consume")
    }

    section("overwrite — newest activation replaces the previous one")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 111, at: 1000)
        gate.recordAppActivation(pid: 222, at: 1000.2)
        assertEq(gate.consumeRecentActivation(at: 1000.3), pid_t(222), "second record wins")
    }

    // Overwrite also refreshes the timestamp: an old record that would have
    // expired is superseded by a fresh one measured from the new time.
    section("overwrite refreshes the TTL clock")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 1, at: 1000)     // would expire by t=1000.5
        gate.recordAppActivation(pid: 2, at: 1000.4)   // fresh stamp at 1000.4
        // At t=1000.8: 0.8 since first (expired), but 0.4 since second (live).
        assertEq(gate.consumeRecentActivation(at: 1000.8), pid_t(2), "TTL measured from newest record")
    }

    section("record after consume works (record is reusable)")
    do {
        var gate = FocusEventGate()
        gate.recordAppActivation(pid: 10, at: 1000)
        _ = gate.consumeRecentActivation(at: 1000.1)
        gate.recordAppActivation(pid: 20, at: 1000.2)
        assertEq(gate.consumeRecentActivation(at: 1000.3), pid_t(20), "re-record after consume")
    }
}
