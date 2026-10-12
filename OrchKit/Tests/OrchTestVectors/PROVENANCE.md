# vectors_v2.json and http_fixtures provenance

- Source: orch-relay `tests/vectors_v2.json` (protocol v2 test vectors, `docs/protocol-v2.md` sections 7.2/7.3, 16 and 19) and
  `tests/http_fixtures/` (relay HTTP v2 examples, section 19), the whole directory including the relay's `manifest.py` and `MANIFEST.json`.
- orch-relay commit: `04da0e7` (develop after orch-relay #50 "G3b pairing attempt binding (P3-D28)", on top of d3816ea's G2b and Q11
  vectors); last commit touching vectors or fixtures: `798c4ace2ff98c3db230b2cbcc67714a657be477`.
- Copied: 2026-10-11, unmodified. Re-copy both together and update this file; never edit the JSON by hand.
- Test targets reach the vectors through `OrchTestVectors` (`Vectors.data`) and the fixtures through `Fixtures` (same target).
- The fixture files are pinned by the relay's own manifest: `fixtureFilesMatchTheRelaysManifest` checks every file's SHA-256 against
  `MANIFEST.json`, recomputes its aggregate, and requires the directory to hold exactly the manifest's files.
- MANIFEST.json revision 6, aggregate `2b3b0f3278257d67d77fbe90a0c119d8175b90de032fffb485db265b00465f49`
- The Q10 vectors (`wk_commit`, `member_lists` 34 cases, `member_list_snapshots` 13 cases) come from this copy; the earlier local
  stand-ins (`local_g2b_vectors.json`, its generator, the PreG2b re-sign shim) are gone.
- Not implemented here (stage "Q11", SkipList.swift): `p3.restore` (34 vectors per suite) and the bridge_host_post cases
  `expired_identical_chunk_restored` and `refusal_409_retry_exhausted`.

vectors_v2.json sha256: `717b519025740348b35eecf80d9699d4cc7961ba79183bbfad00bd0769315734`
