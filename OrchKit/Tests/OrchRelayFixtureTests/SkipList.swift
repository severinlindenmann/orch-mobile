/// Which relay HTTP v2 fixture routes the mobile relay adapter can replay (behaviour, not wire shape), and which PR enables the rest.
///
/// PR1 (this one) is test-only plumbing: the adapter still speaks the old wire, so NO case is replayable yet and every case is
/// pending. Each later PR moves its files from `pending` to `replayable` in the same change that adds the replay test; the
/// coverage test fails if a case falls out of both lists, is in both, or if a listed file no longer exists. The set of
/// cases can therefore neither shrink silently (a fixture re-copy that drops cases changes `expectedCaseCount`) nor be skipped silently.
enum FixtureCoverage {
    enum PR: String, CaseIterable {
        /// Wire `/v2` paths and no `host_api` field: session, host hold/poll (the transport the other PRs build on).
        case pr2 = "PR2 wire /v2 + no host_api"
        /// Membership and persons: card, member lists, grants, card keys, devices, revocations.
        case pr3 = "PR3 membership/persons"
        /// Pairing, accounts, primary device and cert requests (challenge, rejection, polling).
        case pr4 = "PR4 pairing/primary/cert_rejection"
        /// Bridge: 202 acceptance, 429 quota/rate limiting, 409 stale_epoch and the rest of the bridge refusals.
        case pr5 = "PR5 bridge 202/429/stale_epoch"
    }

    /// Pending, by fixture file.
    static let pending: [String: PR] = [
        "session_challenge.json": .pr2, "session_login.json": .pr2, "session_logout.json": .pr2,
        "host_hold.json": .pr2, "host_poll.json": .pr2,

        "card_get.json": .pr3, "card_put.json": .pr3, "card_key.json": .pr3, "card_keys.json": .pr3,
        "grants.json": .pr3, "members.json": .pr3, "membership.json": .pr3,
        "device_get.json": .pr3, "device_put.json": .pr3,
        "revocation_feed.json": .pr3, "revocation_get.json": .pr3, "revocations_post.json": .pr3,

        "accounts.json": .pr4, "pair_device_post.json": .pr4, "pair_host_post.json": .pr4, "pair_poll.json": .pr4,
        "cert_challenge.json": .pr4, "cert_rejection.json": .pr4, "cert_request_get.json": .pr4,
        "cert_requests_poll.json": .pr4, "cert_requests_post.json": .pr4,

        "bridge_device_poll.json": .pr5, "bridge_device_post.json": .pr5, "bridge_host_post.json": .pr5
    ]

    /// Per-case overrides of `pending` (case id -> PR), for cases whose enabling PR differs from the rest of their file. None yet.
    static let caseOverrides: [String: PR] = [:]

    /// Fixture files whose cases the adapter replays today (all cases of the file). Empty in PR1.
    static let replayable: Set<String> = []

    /// Pinned by the 386a6cb copy: 29 JSON files, 298 cases. Update together with PROVENANCE.md.
    static let expectedFileCount = 29
    static let expectedCaseCount = 298
}
