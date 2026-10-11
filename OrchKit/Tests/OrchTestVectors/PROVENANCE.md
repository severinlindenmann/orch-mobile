# vectors_v2.json and http_fixtures provenance

- Source: orch-relay `tests/vectors_v2.json` (protocol v2 test vectors, `docs/protocol-v2.md` section 16 and 19) and `tests/http_fixtures/` (relay HTTP v2 examples, section 19)
- orch-relay commit (origin/develop when copied): `386a6cb9236612a262884d1005f431a0f548b5b0`
- Last commit touching vectors or fixtures upstream: `759a192fc357fc94acab154e864ef44b7f4ce856`
- Copied: 2026-10-11, unmodified. Re-copy and update this file together; never edit the JSON by hand.
- Test targets reach the vectors through the `OrchTestVectors` target (`Vectors.data`) and the fixtures through `Fixtures` (same target), which hold the only copies.

sha256: `d1ee18aef4cf488b2bc58fe512b94e699f4b7c810e5bf1e405559369ff54b184`

## http_fixtures (sha256 per file)

- accounts.json: sha256 `25068c96173a565bfc86917e454136df2dafa9b8642d3badb8ea89a1cc1151cc`
- bridge_device_poll.json: sha256 `3e6ba249aa83db67c2da3e34d7d8923c9ca3d429525e513215dc0dfc123493b2`
- bridge_device_post.json: sha256 `5716a532ae884a26fbe69ee9c1a4ffc414f7fa0a72c1b37d040510988521a06f`
- bridge_host_post.json: sha256 `90841a23fc737c5f719e24bdd98ba71f991ae4d8f67685519093ca294e50940e`
- card_get.json: sha256 `6e00a623862e6b2c4cdf3b74c4b1efa3b4da59ed4dc7d2518f33d018108255c5`
- card_key.json: sha256 `94c1dd1ebc6984b9a9feedc6ee804756519f0c0a3429a1ef0b552004a2519a9a`
- card_keys.json: sha256 `ddb9bcd383522bc7dcd6d41a208d72c25882057d40329567ad34faed1f7cc6a3`
- card_put.json: sha256 `a57ac8cefd653d093a5f36785bf7fd9a88b8b52fc67f6d622c561b1c4fac1f4e`
- cert_challenge.json: sha256 `f95005734f6fe03d7dd76de297f5514351b5113f231aeb5bc6db180412529640`
- cert_rejection.json: sha256 `8d5c50c3effc274378d932d38ccf569d2739edadcc87d27eacd3511bf34699cd`
- cert_request_get.json: sha256 `7845c1037834a858fbf0ff8d7c99e660020c890b3e59a4de3c5fa42a11ade420`
- cert_requests_poll.json: sha256 `54de4eef6422a6e1111e46cf5ea3b3e0cf5afcfb8a89c7ad38fd1f06eb391d62`
- cert_requests_post.json: sha256 `9b114ae439cd5a61866d9a22bb0e94c0679f7a71816cac80a686ebce282b8a8d`
- device_get.json: sha256 `ff37825adf657c46cc4c0b380a86838b16a67875ecabd417901681fc794196a1`
- device_put.json: sha256 `448656fea7366cd8e61fbbaaa2f8e39a28c6b6ba81fe7c53b9b2555916e10187`
- grants.json: sha256 `accfe157b6b57fd72fc1b86697596343d6bdd68f2cf8680f26a64e4ef56e3591`
- host_hold.json: sha256 `3e53d3d685b0beb747890b1ca83d4af506f75cffc787ee8948e56803b5925fc7`
- host_poll.json: sha256 `12a469ebff190edfdef849bb7def2f80fb98ce522f1fbe3a71815c34cdfaf6fb`
- members.json: sha256 `9d23e83755fc1c45d36bfdd15f76890fe3efc164f6fea5988550d921ed21c434`
- membership.json: sha256 `93f06639393abaf2de3593f0924000b0c74e3046c66dc3637b18bfffd4775e71`
- pair_device_post.json: sha256 `1b7a756952f1419a0dd1a8334834559c32af1f17aa76ea4a0c9fa321597ac98f`
- pair_host_post.json: sha256 `8b10f584a8b3b5c594fb7753e619745d9e2eb55184b92685b1b094880a189297`
- pair_poll.json: sha256 `a75a694e983d34d57c4dc61b1b1113e53bb7b0dc3d213c63d2f65cf20ee15295`
- revocation_feed.json: sha256 `66fadcc488dd22f0e742e0f815e2e969d169549686594f2bdbdb5c4bb4feb8b2`
- revocation_get.json: sha256 `4ac300cc956bf63f1a6f5c9dfc11b8df4b933d30ef467d0f2a4c00c694452933`
- revocations_post.json: sha256 `f35f4ff8306d89cbaae00d74c6d31e7ceb2e8700d287b2b91dcd857d51b6968e`
- session_challenge.json: sha256 `9095371f87b94bd03200d494ca50202abe6f3620910b0e486d25bac25dc7292e`
- session_login.json: sha256 `ba37d00ab298808f4f1f9d0a62a0c31c6405f4213a317386bbd950ac87978e6d`
- session_logout.json: sha256 `bdbdf700befc2a7872322b8f72d4d022ee1225ed69c81c6680dc1b4c182f9a28`
- README.md: sha256 `a4a11f1d535366d9fd22bc2d9f913c79010fee55191bc46a361e99e88072be58`
