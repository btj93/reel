import CoreGraphics
import Foundation
import Core
import Platform

func runL1SpaceKeyTests() {
    print()
    print("SpaceKey — Space identity (L1)")

    // The whole point of the enum: an authoritative id and an inferred
    // fingerprint must never collide in the savedSpaces dictionary, even when
    // their payloads look similar.
    section("SpaceKey — cases with similar payloads are distinct dictionary keys")
    do {
        var d: [SpaceKey: String] = [:]
        d[.skylight(4)] = "authoritative"
        d[.fingerprint([4])] = "inferred"
        assertEq(d.count, 2, "the two cases never collide")
        assertEq(d[.skylight(4)] ?? "", "authoritative", "skylight case round-trips")
        assertEq(d[.fingerprint([4])] ?? "", "inferred", "fingerprint case round-trips")
    }

    section("SpaceKey — equality is per-case and payload-exact")
    do {
        check(SpaceKey.skylight(4) == SpaceKey.skylight(4), "same sid is equal")
        check(SpaceKey.skylight(4) != SpaceKey.skylight(5), "different sid is not equal")
        check(SpaceKey.fingerprint([1, 2]) == SpaceKey.fingerprint([2, 1]), "Set payload is order-free")
        check(SpaceKey.fingerprint([1, 2]) != SpaceKey.fingerprint([1]), "different set is not equal")
    }

    // saveCurrentSpace refuses to stash an empty key. sid 0 is SkyLight's
    // "no space" sentinel and must be treated exactly like an empty fingerprint.
    section("SpaceKey — isEmpty covers sid 0 and the empty set")
    do {
        check(SpaceKey.fingerprint([]).isEmpty, "empty fingerprint is empty")
        check(!SpaceKey.fingerprint([7]).isEmpty, "non-empty fingerprint is not empty")
        check(SpaceKey.skylight(0).isEmpty, "sid 0 is the no-space sentinel")
        check(!SpaceKey.skylight(1).isEmpty, "a real sid is not empty")
    }

    // Callers branch on this to decide whether fuzzy matching is even legal.
    section("SpaceKey — isAuthoritative distinguishes fact from inference")
    do {
        check(SpaceKey.skylight(4).isAuthoritative, "skylight is authoritative")
        check(!SpaceKey.fingerprint([1, 2]).isAuthoritative, "fingerprint is inferred")
        assertEq(SpaceKey.fingerprint([1, 2]).fingerprintValue?.count ?? 0, 2, "fingerprint payload readable")
        check(SpaceKey.skylight(4).fingerprintValue == nil, "skylight has no fingerprint payload")
    }

    // Deterministic cover for the empty-name trap. The live-reading check below
    // cannot exercise this: it only ever sees whichever Space is active, and on a
    // normal setup that Space has a real UUID — so a regression here would pass
    // unnoticed. This pins the invariant regardless of machine state.
    section("normalizedSpaceUUID — blank names are not identities")
    do {
        check(normalizedSpaceUUID("") == nil, "empty string is not an identity (sid 1 returns this)")
        check(normalizedSpaceUUID(nil) == nil, "nil stays nil")
        check(normalizedSpaceUUID("   ") == nil, "whitespace-only is not an identity")
        assertEq(normalizedSpaceUUID("0472AB3C-F9C4-4492-A08C-4C26533286FA") ?? "",
                 "0472AB3C-F9C4-4492-A08C-4C26533286FA", "a real UUID passes through unchanged")
    }

    // The shim must be safe to call unconditionally. Where the symbols exist it
    // returns a real reading; where they do not it returns nil. Both are correct —
    // what must never happen is a crash or a fabricated value.
    //
    // NOTE: deliberately does NOT compare two separate live readings. This suite
    // gates every commit and runs on the author's daily driver, so a Space switch
    // (or Mission Control, which makes the live Space type 3) between two reads
    // would fail the build for no reason.
    section("SpaceIdentity — contract holds whether or not SkyLight is present")
    do {
        print("      \(SpaceIdentity.diagnostics)")
        let snap = SpaceIdentity.currentSpace()
        if SpaceIdentity.isAvailable {
            check(snap != nil, "available shim returns a reading")
            if let snap {
                check(snap.sid != 0, "a real sid is never the 0 sentinel")
                check(!snap.key.isEmpty, "a real reading yields a non-empty SpaceKey")
                check(snap.key.isAuthoritative, "a real reading is authoritative")
                // SLSSpaceCopyName returns "" for the unnamed first Space; an
                // Optional("") would become a disk key aliasing every such Space.
                check(snap.uuid != "", "an empty Space name is normalized to nil, never Optional(\"\")")
            }
        } else {
            check(snap == nil, "unavailable shim returns nil, never a fabricated value")
        }

        // A display that does not exist must yield nil, NOT another display's
        // Space. Falling back to the global active Space here would stamp a
        // hot-plugging display with the cursor display's identity.
        let bogus = SpaceIdentity.currentSpace(displayID: CGDirectDisplayID(0xFFFF_FFFE))
        check(bogus == nil, "an unknown display yields nil, never another display's Space")
    }
}
