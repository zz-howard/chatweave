# Protocol 0.1 conformance fixtures

`manifest.json` is the exhaustive inventory. Paths are relative to this directory.

- `file` contains one protocol object, checked against `schema`.
- `events` is UTF-8 JSON Lines; `expected` is its normative folded message.
- Omitted `rejectAt` means success; `schema`, `semantic`, and `limits` identify the rejection layer.
- `mode: consumer` permits unknown event/block types without admitting unregistered production types.
- `legacySteps: true` models a client that ignores steps while still advancing seq.
- `resumeAfter` records the disconnect cursor; repeated events remain intentionally in the file.
- `customSchemas` registers the fictional todo type for strict producer validation.

`action-scenarios.json` holds ordered dispatcher scenarios: seedMessage, requests, results, expectedMessage, plus explicit authorization decisions / executeCount where applicable. Request/result objects are also individually inventoried in the manifest. A scenario runner uses a fixed clock at 2026-10-26T09:31:00Z and a resolver identity omitted for a one-to-one conversation. The interrupt-other-device case installs its concurrentAnswer before dispatch.

All data is fictional weather and todo data. Expected messages were specified independently of the Rust implementation. Test runners must fail for an empty inventory, missing file, unhandled kind, or a fixture that is never exercised.
