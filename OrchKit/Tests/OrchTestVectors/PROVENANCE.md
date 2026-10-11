# vectors_v2.json and http_fixtures provenance

- Source: orch-relay `tests/vectors_v2.json` (protocol v2 test vectors, `docs/protocol-v2.md` sections 7.2/7.3, 16 and 19) and
  `tests/http_fixtures/` (relay HTTP v2 examples, section 19), the whole directory including the relay's `manifest.py` and `MANIFEST.json`.
- orch-relay commit: `d3816eac6afd926fbf5c22469649bf3024493cab` (develop after orch-relay #48 "P3 G2b: member-list wk_commit,
  burned epochs, wk_commit_changed (P3-D26)" and the Q11 exact-bytes re-store merge); last commit touching vectors or fixtures: `eea1dd9616dd66de985cbfe4e937196512f4b091`.
- Copied: 2026-10-11, unmodified. Re-copy both together and update this file; never edit the JSON by hand.
- Test targets reach the vectors through `OrchTestVectors` (`Vectors.data`) and the fixtures through `Fixtures` (same target).
- The fixture files are pinned by the relay's own manifest: `fixtureFilesMatchTheRelaysManifest` checks every file's SHA-256 against
  `MANIFEST.json`, recomputes its aggregate, and requires the directory to hold exactly the manifest's files.
- MANIFEST.json revision 5, aggregate `125f8e684e26d02051ac27145b2b5bb3bb3970d9bbf9304b1376e0d1ed06fa6f`
- The Q10 vectors (`wk_commit`, `member_lists` 34 cases, `member_list_snapshots` 13 cases) come from this copy; the earlier local
  stand-ins (`local_g2b_vectors.json`, its generator, the PreG2b re-sign shim) are gone.
- Not implemented here (stage "Q11", SkipList.swift): `p3.restore` (34 vectors per suite) and the bridge_host_post cases
  `expired_identical_chunk_restored` and `refusal_409_retry_exhausted`.

vectors_v2.json sha256: `5b766a461e12e13b5abc166864739f852572dc8f40a1000e2c2dc5ffd921cfe5`
