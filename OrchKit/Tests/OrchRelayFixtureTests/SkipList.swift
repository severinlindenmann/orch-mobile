/// Which relay HTTP v2 fixture routes the mobile relay adapter can replay (behaviour, not wire shape), and which PR enables the rest.
///
/// PR1 was test-only plumbing (every case pending). PR2 moves the wire to `/v2` without `host_api` and enables the session
/// files; host_hold and host_poll are host-only routes (orch-core), which the phone never calls, so they stay pending here.
/// Each later PR moves its files from `pending` to `replayable` in the same change that adds the replay test; the
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
        /// F1 ticket log routes (genesis, baselines, checkpoints, proofs, staging, transitions): host and relay; the phone has no
        /// client for them yet (gaps.md #25).
        case f1 = "F1 ticket log / checkpoints"
        /// Q11 exact-bytes re-store of an expired identical chunk (orch-relay d3816ea): implemented in a later change.
        case q11 = "Q11 exact-bytes re-store"
    }

    /// Pending, by fixture file.
    static let pending: [String: PR] = [
        // host-only routes (orch-core); the phone has no client for them, so they stay pending with PR2's other leftovers
        "host_hold.json": .pr2, "host_poll.json": .pr2,
        "baseline_delete.json": .f1, "baseline_post.json": .f1, "checkpoint_get.json": .f1, "checkpoint_put.json": .f1,
        "genesis.json": .f1, "proof.json": .f1, "staging_manifest.json": .f1, "staging_page.json": .f1, "transitions.json": .f1,
    ]

    /// PRs whose files are all replayable now.
    static let done: Set<PR> = [.pr3, .pr4, .pr5]

    /// Per-case overrides (case id -> PR), for cases whose enabling PR differs from the rest of their file. An override wins over
    /// `replayable`: the case is pending even though its file replays. The G2b copy pins every membership outcome; the two Q11 bridge
    /// cases wait for the Q11 change.
    static let caseOverrides: [String: PR] = ["bridge_host_post.json#expired_identical_chunk_restored": .q11,
                                              "bridge_host_post.json#refusal_409_retry_exhausted": .q11]

    /// Vector groups (not HTTP fixtures) that no test runs yet, by the stage that will: `p3.restore` (34 per suite) is Q11.
    static let pendingVectorGroups: [String: PR] = ["p3.restore": .q11]

    /// Fixture files whose cases the FakeRelay replays today (all cases of the file; see RelayReplayTests).
    static let replayable: Set<String> = ["session_challenge.json", "session_login.json", "session_logout.json",
                                          "accounts.json", "pair_device_post.json", "pair_host_post.json", "pair_poll.json",
                                          "cert_challenge.json", "cert_rejection.json", "cert_request_get.json",
                                          "cert_requests_poll.json", "cert_requests_post.json",
                                          // PR3: directory and membership (RelayReplayTests + PR3Replay seeds)
                                          "card_get.json", "card_put.json", "card_key.json", "card_keys.json",
                                          "grants.json", "members.json", "membership.json",
                                          "device_get.json", "device_put.json",
                                          "revocation_feed.json", "revocation_get.json", "revocations_post.json",
                                          // PR5: bridge (RelayReplayTests bridge seeds)
                                          "bridge_device_post.json", "bridge_device_poll.json", "bridge_host_post.json"]

    /// Pinned by the d3816ea copy (MANIFEST.json revision 5): 38 JSON fixture files, 396 cases. Update together with PROVENANCE.md.
    static let expectedFileCount = 38
    static let expectedCaseCount = 396
}
