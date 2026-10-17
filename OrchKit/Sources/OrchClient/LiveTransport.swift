import Foundation

/// The Live realm's relay transport: the real byte path (`RoutedRelayTransport`, protocol-v2 section 19) over `NWRequestSender` for the
/// ONE https origin of a live `RealmContext`. This is the only public way to obtain a Live transport; the routed initializer itself is
/// `package`, so an app cannot pair a live context with a sender of its own choosing.
///
/// An app that supplies its own `RelayTransport` instead is not prevented from doing so by this type: `LiveRuntime` checks that such a
/// transport reports the runtime's own context (same lifetime, origin and realm), and `WorkspaceSession.init` re-checks the lifetime.
/// A transport that merely returns the right context from its `context` property would pass those checks; nothing here can prove it
/// actually refuses to send after invalidation.
///
/// The transport shares the context's `RealmGeneration`: invalidating the context stops every send on it (checked immediately before the
/// sender is touched), which is what lets a runtime that owns exactly one context cut off all of its sessions at once.
public enum LiveTransport {
    /// Address recorded in each `WireRequest`. The real sender never transmits it (the relay sees the socket peer); it exists for the
    /// in-process fake, which rate-limits by it.
    static let clientAddress = "0.0.0.0"

    /// A transport for `context` (a `RealmContext.live` context). Throws `RealmViolation` for a Demo context or any origin the
    /// context does not admit, before anything is opened.
    public static func make(context: RealmContext) throws -> some RelayTransport {
        guard context.realm == .live else { throw TransportError.realm(.wrongTransport) }
        return try RoutedRelayTransport(context: context, origin: context.origin, sender: try NWRequestSender(origin: context.origin),
                                        clientAddress: clientAddress)
    }

    #if DEBUG
    /// TEST-ONLY: the same transport over an injected `RequestSender` (a scripted fake) instead of the network. It exists only in DEBUG
    /// builds of OrchClient (Release has no such symbol), and `scripts/check-no-test-hooks.sh` fails the build if a shipped target names
    /// it. The sender must be on the context's origin, as always.
    public static func testingTransport<S: RequestSender>(context: RealmContext, sender: S) throws -> some RelayTransport {
        guard context.realm == .live else { throw TransportError.realm(.wrongTransport) }
        return try RoutedRelayTransport(context: context, origin: context.origin, sender: sender, clientAddress: clientAddress)
    }

    /// TEST-ONLY (DEBUG UI tests): a live transport whose relay never answers, so a pairing stays at "connecting". Same rules as
    /// `testingTransport`: DEBUG builds of OrchClient only, and `scripts/check-no-test-hooks.sh` keeps it out of shipped targets.
    public static func unreachableForUITests(context: RealmContext) throws -> some RelayTransport {
        try testingTransport(context: context, sender: UnreachableSender(origin: context.origin))
    }

    private struct UnreachableSender: RequestSender {
        let origin: String
        func send(_ request: WireRequest) async throws -> WireReply { throw TransportError.disconnected }
    }
    #endif
}
