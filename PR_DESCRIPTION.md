# Implement CW1: ChatWeave 0.1 Rust core (T0–T4)

ChatWeave now has a host-independent Rust protocol core and server helpers for producing, persisting, resuming and interacting with mixed Markdown/structured messages. A paused run resumes in the same message and sequence; disconnected consumers do not stop generation. Action retries recheck current authorization before returning any saved result.

## Scope

- **T0:** Rust workspace, Rust 1.99.1 / edition 2024, empty Dart core and Flutter packages, Flutter 3.47.8 CI, dependency and vocabulary boundaries, and one schema/conformance entry point.
- **T1:** Protocol and JSON Schema 0.1 finalization, 35 positive event-stream pairs, structural/semantic/resource-limit negatives, all ten built-in block types, action scenarios and generation-control fixtures. The manifest indexes every fixture and rejects empty or unregistered coverage.
- **T2:** Lossless serde wire values, typed built-in block data, offline JSON Schema validation, stricter configurable limits, custom schemas and deterministic folding with sequence/revision checks, steps and interrupts.
- **T3:** Stream and step handles, nested delegation, pause/resume, explicit stopping, checkpoints, bounded in-memory logs, broadcast subscriptions, replay/snapshot handover, optional Axum SSE, generation identity/active-message helpers, recovery and a Markdown-only adapter.
- **T4:** Generic action handlers, registry and dispatcher, request-bound receipts and an in-memory transaction store. The execution claim covers validation through commit so concurrent answers cannot both execute.

The Dart packages remain empty scaffolds with placeholder tests; client protocol/rendering implementation is outside T0–T4. Persistent storage, authentication, business handlers and agent runtime state remain application responsibilities.

## New block lifecycle wire shape

Blocks retain their original `id`, `type` and `schemaVersion` even when component data is pending or unavailable. The optional block-level `status` is separate from an interactive block's `data.state.status`.

```json
{
  "id": "b2",
  "type": "metric",
  "schemaVersion": 1,
  "status": "pending",
  "fallbackText": "Forecast pending"
}
```

```json
{
  "id": "b2",
  "type": "metric",
  "schemaVersion": 1,
  "status": "error",
  "reason": "Weather service unavailable",
  "fallbackText": "Forecast unavailable"
}
```

- An omitted status means `complete`; completed blocks require data valid for their original type.
- `pending` means `block.end` has not arrived. It remains pending after `block.data`, so snapshots preserve enough lifecycle information to accept the later end event. Pending/error blocks may omit `data`, but always require `fallbackText`.
- Error blocks may carry a safe `reason` string of at most 500 characters. They do not fabricate domain values or change into Markdown blocks.
- Streaming checkpoints/snapshots may contain pending blocks. Paused and ended messages may not.
- Folding a successful `block.end` removes the lifecycle status; a failed end records `error` and its fallback/reason.

## Protocol and Schema finalization

1. Same-ID action retries first load the scoped block and compare their normalized request binding. Changed bindings return `invalid_request`. A matching committed request skips the original declaration/state/payload/destructive checks, but always reruns `authorize` at step 5 before receipt replay at step 6. Binding data is stored with the receipt.
2. A destructive confirmation's interrupt `cancel`/`freeText` response records an answer and resumes the runtime after validation and authorization; it does not invoke destructive `execute`. Actual destructive execution still requires a destructive confirmation and `confirm`.
3. Add the pending/error block lifecycle representation above, including snapshot continuation and prohibition of pending blocks in paused/final messages.
4. Current-state action patches permit `rev >= 1`, including an interrupt closed before its first final persistence. A new persistent modification still increments the current revision.
5. Enforce `resume`/`patches` and `resume`/`followUp` mutual exclusion in ActionResult Schema.
6. Merge Patch accepts null deletions. The resulting complete block must still satisfy its schema, so deleting a required field does not bypass validation.
7. Distinguish Schema structure, cross-event semantics and resource limits in the manifest and T1 acceptance criteria. `tool/validate_schemas` runs all three layers through the Rust conformance runner.
8. Missing interaction state means open without inserting a field during serialization. Constrain answer fields to the block kind and recorded status; distinguish user cancellation from server invalidation.
9. Describe the two deterministic handover hook stages accurately: `AfterSubscribe` and `AfterReplay`.
10. Distinguish no automatic reconnect after pausing from the initial one-off subscription used to obtain a paused replay/snapshot on a new consumer.
11. A stream-level error closes its connection. A generation failure is represented by `message.end`, not a stream error followed by more events.
12. Folding reads no system clock: `message.end.ts` supplies `completedAt` when present, otherwise it remains absent. Byte limits mean UTF-8 bytes/KiB; character limits follow JSON Schema lengths.
13. `Last-Event-ID` takes priority over `after`, including when malformed. Invalid and future cursors return explicit errors rather than being clamped.
14. Replace application-specific schema/protocol examples with generic task/weather examples and update the security description of all three interrupt free-text actions.

## Replay and authorization tests

The replay implementation subscribes before reading any log or snapshot. It discards overlapping live events by sequence, repairs gaps from the log and disconnects a lagged consumer. The tests use gates and controlled transports rather than relying on sleeps to hit a race.

- `subscribe_precedes_every_initial_log_read`
- `a_last_end_written_during_the_log_read_cannot_be_lost_at_subscription`
- `after_replay_writes_including_last_end_are_complete_unique_and_ordered`
- `after_subscribe_writes_are_deduplicated_against_log_replay`
- `handover_gap_is_backfilled_from_log_before_the_end_is_emitted`
- `lagged_receiver_closes_stream_instead_of_skipping_events`
- `lagged_sse_body_disconnects_instead_of_delivering_a_terminal_frame`

The HTTP integration suite additionally drops a streaming body mid-message, resumes with `Last-Event-ID` and compares the joined fold with the complete fixture. It covers cleared-log snapshots, unsupported snapshots, response headers, heartbeat comments and activity frames without IDs.

`revoked_permission_is_checked_before_a_successful_receipt_is_replayed` succeeds once, revokes authorization, retries the exact same action ID, and requires a forbidden result without replay. It also checks the call trace `authorize, execute, authorize` and a single execution.

### Negative controls

Apply each mutation independently on a disposable checkout and revert it after the corresponding test fails:

| Mutation | Expected failing test/check |
|---|---|
| Import `package:flutter/widgets.dart` in `chatweave_core` | `tool/check_deps`; `test_flutter_import_in_core_is_rejected` exercises this injection in a temporary directory |
| Add `axum = "0.8"` to protocol dependencies | `tool/check_deps`; `test_axum_dependency_in_protocol_is_rejected` |
| Add a prohibited generic business term such as `ledger` to library source | `tool/check_host_terms`; `test_business_term_in_library_is_rejected` |
| Move initial log reading before live subscription | `subscribe_precedes_every_initial_log_read` and `a_last_end_written_during_the_log_read_cannot_be_lost_at_subscription` |
| Remove the subscription before/after-replay overlap protection | Handover tests require complete, unique, increasing sequences ending in `message.end` |
| Swallow broadcast Lagged instead of closing | `lagged_receiver_closes_stream_instead_of_skipping_events` and the HTTP-body disconnect test |
| Return a saved receipt before calling `authorize` | `revoked_permission_is_checked_before_a_successful_receipt_is_replayed` |

The boundary negative controls run with a fake Cargo executable and temporary repositories; they neither modify this checkout nor compile Rust.

## Validation and build-machine handoff

Local validation is static only. TOML/YAML parsing, `bash -n`, the boundary-script negative controls and vocabulary checks have been run. Rust compilation, rustfmt, clippy, Rust conformance tests and Dart/Flutter tooling have **not** been run here: the implementation machine has no Cargo or Flutter, and no tools were installed.

Run on the x86_64 build machine:

```bash
cd rust
cargo fmt --all --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace
cargo test --workspace --all-features
cd ..
tool/check_deps
tool/check_host_terms
tool/validate_schemas
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/tests -v
cd dart
flutter pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
cd packages/chatweave_core
dart test
cd ../chatweave_flutter
flutter test
```

`Cargo.lock` is not hand-written. The build machine generates the lockfile for a subsequent commit. The first compiler/formatter pass must confirm the handwritten Rust code, `jsonschema 0.29.0` APIs, Axum 0.8/Axum Test 17.3 integration and workspace package resolution. No compiled or runtime success is claimed by this PR description until those results are available.

Dependencies use serde/serde_json 1, jsonschema exactly 0.29.0 with all default IO features disabled, thiserror 2, Tokio 1, async-trait 0.1, futures 0.3, async-stream 0.3, uuid 1, time 0.3, pulldown-cmark 0.13, sha2 0.10, optional Axum 0.8.3 and test-only Axum Test 17.3.0/http-body-util 0.1. Compatible version ranges resolve on the build machine; this list does not assert ungenerated lockfile versions.
