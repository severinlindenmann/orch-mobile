import Foundation
import OrchCustody
import OrchProtocol
import OrchStore

/// Everything restoring a realm's workspaces needs. The realm is the context's; `transport` must share its generation.
public struct RestoreConfig: Sendable {
    public var context: RealmContext
    public var transport: any RelayTransport
    /// The realm index (already bound to the context's fence by the caller, or bound here by the first session).
    public var index: WorkspaceIndex
    /// The `.keys` vault; sessions receive only the context realm's view of it.
    public var vault: SecretVault
    public var custody: any DeviceKeyCustody
    public var clock: any Clock<Duration>
    public var wall: any WallClock
    public var entropy: any Entropy
    /// H12d: the running build's runtime KAT result and identity.
    public var reader: ReaderRuntime

    public init(context: RealmContext, transport: any RelayTransport, index: WorkspaceIndex, vault: SecretVault, custody: any DeviceKeyCustody,
                clock: any Clock<Duration>, wall: any WallClock, entropy: any Entropy = SystemEntropy(), reader: ReaderRuntime = .production) {
        self.context = context; self.transport = transport; self.index = index; self.vault = vault; self.custody = custody
        self.clock = clock; self.wall = wall; self.entropy = entropy; self.reader = reader
    }
}

/// What a restore produced: the rebuilt workspaces, and the committed ones that could not be rebuilt (with a stable reason tag; they stay
/// in the index untouched, nothing is erased on a failed restore).
public struct RestoreOutcome: Sendable {
    public var handles: [JoinedHandle] = []
    public var skipped: [(ws: String, reason: String)] = []
}

/// Rebuilds the `WorkspaceSession`s of workspaces a verified join committed in an earlier launch: from the index row (workspace and
/// generation), the committed `WorkspaceProfile` (pins: `WSK`, owner key, the last accepted card) and the workspace's own durable store, so
/// decisions of unknown outcome and ticket-submission identities are preserved, because they live in that store, not in the session.
///
/// Every session is built on `config.context` and `config.transport` (a runtime owns exactly one realm context; `WorkspaceSession.init`
/// enforces the shared generation). Restoring is read-only with respect to the network: it contacts the relay only when a session later
/// needs it.
public enum WorkspaceRestoration {
    /// Throws for conditions that affect every workspace and may pass: the realm is over, the index is unreadable, the device keys are
    /// temporarily unreachable (`CustodyError.locked`, `.unavailable`). A workspace whose own record fails verification is `skipped`.
    public static func restore(_ c: RestoreConfig) async throws -> RestoreOutcome {
        try c.context.generation.check()
        guard c.transport.context.generation === c.context.generation else { throw RealmViolation.wrongTransport }
        var out = RestoreOutcome()
        let rows = try await c.index.workspaces()
        if rows.isEmpty { return out }
        // The device keys are realm-level: one lookup for every workspace. Never created here (a restore must not invent an identity).
        let identity = try c.context.deviceIdentity(custody: c.custody, createIfMissing: false)
        do {
            for row in rows {
                try c.context.generation.check()
                switch await c.index.removalStatus(ws: row.ws, generation: row.generation) {
                case .removed: out.skipped.append((row.ws, "removed")); continue
                case .unknown: throw StoreError.removalStateUnknown(ws: row.ws, generation: row.generation)
                case .notRemoved: break
                }
                do { out.handles.append(try await rebuild(row, identity: identity, c)) }
                catch let e as RestoreSkip { out.skipped.append((row.ws, e.reason)) }
            }
        } catch {
            // All or nothing for the caller: what rows 1..N-1 built is released, so a retry never finds duplicate sessions or containers.
            await release(out.handles)
            throw error
        }
        return out
    }

    private struct RestoreSkip: Error { let reason: String }

    /// Ends the sessions of restored handles and closes their containers (a boot that failed after restoring, or a retired realm).
    public static func release(_ handles: [JoinedHandle]) async {
        for h in handles {
            await h.joined.session.realmShutdown()
            await h.joined.downloadContainer.close()
        }
    }

    private static func rebuild(_ row: WorkspaceEntry, identity: DeviceIdentity, _ c: RestoreConfig) async throws -> JoinedHandle {
        guard let ws = ID16(hex: row.ws) else { throw RestoreSkip(reason: "workspace_id") }
        guard let p = try await c.index.profile(ws: row.ws) else { throw RestoreSkip(reason: "no_profile") }
        // The profile's origin is what the join used; a Live install has exactly one origin, and an existing graph is never retargeted.
        guard p.origin == c.context.origin else { throw RestoreSkip(reason: "origin") }
        guard let wskBytes = B64U.decode(p.wskPub), let pkBytes = B64U.decode(p.pkPub),
              let wsk = try? SigningPublicKey(x963: wskBytes), let pk = try? SigningPublicKey(x963: pkBytes),
              Identifiers.personID(pk).hex == p.ownerPerson,
              let json = try? StrictJSON.parse(p.card), let card = try? Card.verify(json, ownerKey: pk),
              card.workspace == ws, card.wsk == wsk else { throw RestoreSkip(reason: "pins") }
        if let pinned = c.context.pinnedOwner, pinned != pk { throw RestoreSkip(reason: "owner") }
        // H12d (O3): a build below the highest level declared for this workspace never opens it ("Update orch to open this workspace")
        let marker: ReaderStateRecord?
        do { marker = try ReaderStore.load(c.vault.scoped(to: c.context.realm), ws: ws) } catch { throw RestoreSkip(reason: "reader_state") }
        guard ReaderGate.opens(marker, runningLevel: c.reader.level) else { throw RestoreSkip(reason: ReaderGate.skipReason) }
        let container = try await WorkspaceContainer(index: c.index, ws: row.ws, generation: row.generation, fence: c.context.generation)
        let cfg = WorkspaceSessionConfig(context: c.context, workspace: ws, generation: row.generation, identity: identity, wsk: wsk,
                                         container: container, vault: c.vault.scoped(to: c.context.realm), transport: c.transport,
                                         clock: c.clock, wall: c.wall, entropy: c.entropy, reader: c.reader)
        let session: WorkspaceSession
        do { session = try await WorkspaceSession(cfg) }
        catch { await container.close(); throw error }
        let joined = JoinedWorkspace(workspace: ws, generation: row.generation, name: p.name,
                                     hosted: HostedMarker.decide(delegationClientHosted: p.hostedMarker, hostedBy: p.hostedBy),
                                     scopes: p.scopes, epoch: UInt32(clamping: p.epoch), origin: p.origin, session: session, dropCard: card)
        return JoinedHandle(joined: joined)
    }
}
