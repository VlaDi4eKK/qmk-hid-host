---
stepsCompleted: ["step-01-validate-prerequisites", "step-02-design-epics", "step-03-create-stories"]
inputDocuments:
  - "Code review of qmk-hid-host (chat, 2026-06-27)"
  - "Party-mode backlog stress-test (chat, 2026-06-29)"
---

# qmk-hid-host - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for **qmk-hid-host**, a Rust host daemon that pushes data (time, volume, keyboard layout, media, weather) to QMK keyboards over Raw HID, with a relay mode for device-to-device communication.

No PRD / Architecture / UX documents exist for this brownfield project. The requirements below are derived from a code-review of the current `main` branch (2026-06-27) and refined by a party-mode backlog stress-test (2026-06-29). All eight items are quality attributes of the existing system, so they are captured as Non-Functional Requirements (reliability, testability, maintainability, portability, correctness, operability) rather than new functional behaviour.

## Requirements Inventory

### Functional Requirements

_None. This is a hardening / tech-debt pass over existing functionality; no new user-facing behaviour is introduced._

### NonFunctional Requirements

NFR1 (Reliability): The daemon must not panic on recoverable conditions. A malformed config file, a config write failure, or `HidApi::new()` failing inside the reconnect loop must be handled gracefully (log + exit cleanly, or continue the loop) instead of unwinding the thread. Source: `src/config.rs:59`, `src/config.rs:66`, `src/keyboard.rs:60`; 27 `.unwrap()`/`.expect()` call sites total.

NFR2 (Testability): Core pure logic must be covered by unit tests. At minimum: hex `productId` parse/serialize round-trip (`src/config.rs`), the 32-byte send-buffer truncate/resize logic (`src/keyboard.rs:116`), and temperature parsing (`src/providers/weather.rs:19`). `test.yml` CI exists but `src/` currently has zero `#[test]`.

NFR3 (Release Management): The crate must carry a meaningful, increasing version. `Cargo.toml` is pinned at `version = "0.0.0"`; adopt SemVer and wire it to release tagging.

NFR4 (Maintainability / Protocol Correctness): The HID `DataType` protocol enum must be a single source of truth across platforms. Today `src/data_type.rs` has a divergent macOS variant (`Spotify = 0xAE` instead of `MediaArtist`/`MediaTitle`, no `MediaPlayerLinux`), which can silently desync from firmware.

NFR5 (Portability / Robustness): Weather retrieval must not shell out to the external `curl` binary (`src/providers/weather.rs:12`); use an in-process HTTP client. Temperature parsing must not be lossy `i8` — support values >127 and decimal/fractional formats without silently dropping the reading.

NFR6 (Performance / Concurrency Hygiene): Reader/writer threads must not busy-wait. The `loop { sleep(10ms) }` pattern in `src/keyboard.rs` (`start_write`/`start_read`) masks an underlying busy-loop (likely a non-blocking `device.read`); diagnose the real cause and replace with proper blocking / timeout-based synchronization. **Note (party stress-test): the sleep loop currently doubles as the disconnect detector — naive blocking reads can hang the reader thread forever on unplug, so this is co-designed with NFR7, not independent.**

NFR7 (Correctness / Concurrency): The connected-device counter must not drift. `src/main.rs:144` does `connected_count += if is_connected {1} else {-1}` driven by `try_send` on size-1 channels; dropped messages desync the count. Use a delivery-guaranteed signal so connect/disconnect events cannot be lost.

NFR8 (Operability / Observability): The daemon must terminate cleanly on `SIGTERM`/`SIGINT` (signal threads to stop, close HID handles, exit 0) instead of having its threads torn mid-operation, and it must not fail silently — a fatal startup/config error must reach the user through a visible channel, not only the stderr of a background process. Surfaced during the party-mode backlog stress-test (2026-06-29).

### Additional Requirements

- Daemon-grade error handling: prefer `Result` propagation + structured `tracing` over `unwrap`/`expect` on any non-invariant path (cross-cutting with NFR1).
- Cross-platform parity: changes must compile and behave consistently across Linux / macOS / Windows `cfg` targets (relevant to NFR4, NFR5, NFR6, NFR8).
- **On-wire protocol breakage is version-gated:** any change to the HID byte protocol (NFR4 enum unification, NFR5 temperature encoding) must land on or after the SemVer baseline (NFR3) with a documented version bump, because deployed firmware hard-codes the current discriminants/encoding.

> **Noted security risk — relay path (NOT scheduled as a story).** Untrusted HID input from one device is rebroadcast to all connected devices with no validation, source binding, or rate-limiting: `start_read` (`src/keyboard.rs:136`) forwards any 32-byte frame whose `data[0] == RelayFromDevice` to `device_to_host_sender`, and `RelayProvider` (`src/providers/relay.rs:41`) re-stamps `data[0] = RelayToDevice` and broadcasts it to every device's writer. A compromised/buggy keyboard can therefore drive another keyboard's `raw_hid_receive_kb` (e.g. `layer_move(data[2])`), using the host as a pivot. Surfaced in the 2026-06-29 party-mode stress-test (Vex). Decision: recorded as a known risk only — relay is experimental and a threat-model/hardening pass is a different class of work, deferred out of this hardening epic. Revisit if relay graduates from experimental.

### UX Design Requirements

_Not applicable — no UI surface in scope for this hardening pass (the macOS menu-bar app is out of scope). The one UX-adjacent concern (a background daemon failing silently) is captured as a visible-failure acceptance criterion on Story 1.5, not as a UI story._

### FR Coverage Map

NFR2: Epic 1 (Story 1.1) — unit tests for core pure logic (foundation)
NFR1: Epic 1 (Story 1.2) — graceful error handling, remove panics from config + HID init
NFR7: Epic 1 (Story 1.3) — fix connection-counter race
NFR6: Epic 1 (Story 1.4) — remove reader/writer busy-wait (co-designed with 1.3)
NFR8: Epic 1 (Story 1.5) — graceful shutdown + visible failure
NFR3: Epic 1 (Story 1.6) — SemVer versioning wired to releases
NFR4: Epic 1 (Story 1.7) — unify cross-platform DataType enum (version-gated)
NFR5: Epic 1 (Story 1.8) — in-process HTTP weather client + robust temp parsing (version-gated)

## Epic List

### Epic 1: Daemon Robustness & Maintainability Hardening
Make qmk-hid-host survive recoverable failures without crashing, keep its
connection state and protocol correct, and become testable and releasable —
all without changing user-facing behaviour. Delivered as eight ordered
fix-stories over the existing daemon core (`src/`).
**NFRs covered:** NFR1, NFR2, NFR3, NFR4, NFR5, NFR6, NFR7, NFR8

_Single-epic rationale: all eight items are one tech-debt hardening pass over
the same daemon core. Per BMAD's file-overlap guidance they are consolidated
into one epic with ordered stories rather than split into technical-layer
epics._

_Ordering rationale (revised after the party-mode stress-test): the stories
form two hidden clusters with a shared foundation, so the flat 1→8 sequence
follows that dependency reality:_

- _**Foundation:** 1.1 (tests) lands first so every later refactor has a
  regression net._
- _**Thread-lifecycle cluster:** 1.2 (panics) → 1.3 (counter race) + 1.4
  (busy-wait, co-designed with 1.3 because the sleep loop is today's disconnect
  poll) → 1.5 (graceful shutdown)._
- _**On-wire-protocol cluster:** 1.6 (SemVer baseline) first, because 1.7
  (enum) and 1.8 (temperature encoding) are breaking protocol changes that
  must ship with a version bump._

_Each story remains independently shippable in this order and fits a single
dev-agent context; later stories build only on earlier ones, never the reverse._

## Epic 1: Daemon Robustness & Maintainability Hardening

Make qmk-hid-host survive recoverable failures without crashing, keep its
connection state and protocol correct, and become testable and releasable —
without changing user-facing behaviour.

### Story 1.1: Add unit tests for core pure logic (foundation)

As a maintainer,
I want the pure parsing/transformation logic covered by unit tests before any refactoring begins,
So that the later hardening stories have a regression net and the existing `test.yml` CI catches breakage.

**Acceptance Criteria:**

**Given** the hex `productId` codec (`string_to_hex` / `hex_to_string`, `src/config.rs:76`)
**When** unit tests run
**Then** round-trip and malformed-input cases are asserted (e.g. `"0x0844"` ↔ `0x0844`, invalid hex returns an error).

**Given** the 32-byte send-buffer logic (`truncate(32)` + `resize_with(32)` + leading `0`, `src/keyboard.rs:116`)
**When** unit tests run
**Then** under-length, exact, and over-length inputs all produce a correctly padded/truncated report.

**Given** the temperature parser as it behaves today (`src/providers/weather.rs:19`)
**When** unit tests run
**Then** current representative inputs (`"+12°C"`, negative) are asserted
**And** the suite is structured so Story 1.8 can extend it with the widened-range / decimal cases without rework.

**Given** the CI workflow `test.yml`
**When** the test suite is added
**Then** `cargo test` discovers and runs the new `#[test]` functions and the job passes.

**Given** full HID payloads are logged at `info` level (`src/keyboard.rs:115`, `tracing::info!("sending {:?}", received)`)
**When** logging levels are reviewed alongside this foundation pass
**Then** payload dumps (media titles, relay frames, etc.) are lowered from `info` to `debug`
**And** default-level logs no longer emit raw payload contents.

### Story 1.2: Remove panics from config loading and HID initialization

As a user running qmk-hid-host as a background daemon,
I want the process to handle a bad config file and transient HID errors gracefully,
So that a typo in my config or a USB hiccup does not crash the whole daemon.

**Acceptance Criteria:**

**Given** a malformed `qmk-hid-host.json`
**When** the daemon starts and parses it (`src/config.rs:57`)
**Then** the error is logged via `tracing::error!` with the parse detail
**And** the process exits with a non-zero status instead of panicking on `.unwrap()`.

**Given** the config path is not writable
**When** the daemon tries to write a fresh default config (`src/config.rs:64`)
**Then** the write failure is logged
**And** the process exits cleanly without an `unwrap` panic / backtrace.

**Given** `HidApi::new()` fails inside the reconnect loop (`src/keyboard.rs:60`)
**When** the keyboard thread is trying to connect
**Then** the error is logged and the loop retries after `reconnect_delay`
**And** the keyboard thread is never torn down by an `.unwrap()` panic.

**Given** the full codebase
**When** reviewing the remaining `.unwrap()`/`.expect()` sites (27 today)
**Then** each is either justified by a documented invariant (comment) or converted to `Result` propagation / logged handling
**And** no recoverable runtime path can panic.

**Given** the recovered error paths
**When** they are made testable (extract `load_config` logic away from any hard `process::exit`)
**Then** they are covered by tests using the Story 1.1 harness.

### Story 1.3: Fix the connection-counter race

As a user with one or more keyboards,
I want connect/disconnect events to be counted reliably,
So that providers start and stop based on the true number of connected devices.

**Acceptance Criteria:**

**Given** the connection signalling channel (`src/main.rs:54`, currently `mpsc::channel::<bool>(1)` driven by `try_send`)
**When** a connect or disconnect event fires
**Then** the event is delivered without being silently dropped on a full channel (no lossy `try_send`)
**And** `connected_count` in `start()` always reflects the real number of connected devices.

**Given** rapid connect/disconnect cycling across multiple keyboards
**When** events arrive concurrently
**Then** the counter never goes negative and never drifts above the real device count
**And** providers are started exactly when `connected_count` transitions 0 → >0 and stopped at >0 → 0.

**Given** the chosen fix (e.g. larger/unbounded channel, blocking `send`, or an atomic counter)
**When** the change is reviewed
**Then** the mechanism guarantees delivery or models the count without per-message loss
**And** the rationale is documented in code.

_Coupling note: the disconnect signal feeding this counter originates in the reader/writer threads reworked by Story 1.4 — co-design the signalling so the two land coherently._

### Story 1.4: Remove the reader/writer busy-wait

As a user running the daemon continuously,
I want the HID reader/writer threads to block instead of spin-sleeping,
So that the daemon does not waste CPU and the synchronization is correct by design.

**Acceptance Criteria:**

**Given** the `start_write` and `start_read` loops (`src/keyboard.rs:110`, `:132`) with `sleep(10ms)` per iteration
**When** the root cause of the busy-loop is diagnosed
**Then** the actual cause is identified (e.g. non-blocking `device.read`, missing read timeout) and documented.

**Given** the diagnosed cause
**When** the loops are reworked
**Then** the `sleep(10ms)` compensation is removed and replaced with a proper blocking read / `hid_set_blocking` / timeout-based wait
**And** idle CPU usage is no higher than the current sleep-based approach (measured before/after).

**Given** a keyboard that is physically unplugged while a read is in flight (the edge case raised in the stress-test)
**When** the reader is blocked on `device.read`
**Then** disconnect is still detected within a bounded time (e.g. a read timeout, not an indefinite block)
**And** `is_connected` flips and the reconnect path engages — i.e. removing the poll-sleep must not remove disconnect detection (ties to Story 1.3).

**Given** the reworked threads
**When** data arrives from the host or the keyboard
**Then** it is processed without the up-to-10ms latency floor the sleep introduced.

### Story 1.5: Graceful shutdown and visible failure

As a user running qmk-hid-host as a background daemon,
I want the daemon to stop cleanly on a termination signal and to make fatal errors visible,
So that it does not leave HID handles dangling on exit and does not fail silently where I can't see it.

**Acceptance Criteria:**

**Given** the daemon is running with one or more connected keyboards
**When** it receives `SIGTERM` or `SIGINT`
**Then** the keyboard reader/writer threads and providers are signalled to stop
**And** open HID device handles are released
**And** the process exits with status 0 within a bounded time, with no threads torn mid-write.

**Given** the macOS run path that drives a `CFRunLoop` (`src/main.rs:127`)
**When** a termination signal arrives
**Then** shutdown is handled consistently with the non-macOS path (no platform left tearing threads abruptly).

**Given** a fatal startup/config error (e.g. malformed config from Story 1.2)
**When** the daemon cannot start
**Then** the failure is surfaced through a user-visible channel (e.g. OS notification, a written status/log file at a documented path, or non-zero exit with a clear message), not only the stderr of a background process
**And** the visibility mechanism is documented so a user knows where to look.

**Given** the shutdown logic
**When** coverage is considered
**Then** the stop-signal path is exercised (using the Story 1.1 harness) so a regression that reintroduces abrupt teardown is caught.

### Story 1.6: Adopt SemVer versioning wired to releases

As a maintainer and a user installing releases,
I want the crate to carry a meaningful, increasing version,
So that builds and release artifacts are traceable instead of all reporting `0.0.0` — and so the protocol-breaking stories that follow can be shipped under a real version bump.

**Acceptance Criteria:**

**Given** `Cargo.toml` pinned at `version = "0.0.0"`
**When** versioning is adopted
**Then** the crate version is set to a real SemVer baseline (e.g. `0.1.0`)
**And** the versioning policy is documented (when to bump major/minor/patch), explicitly including "HID protocol change ⇒ version bump".

**Given** the GitHub release workflow
**When** a release/tag is produced
**Then** the published artifact version is derived from / consistent with the `Cargo.toml` version (no `0.0.0` artifacts).

**Given** a running binary
**When** the version is surfaced (e.g. `--version` via clap, or build metadata)
**Then** it reports the real version.

### Story 1.7: Unify the cross-platform DataType protocol enum

As a firmware author and maintainer,
I want a single `DataType` definition shared by all platforms,
So that the HID protocol cannot silently desync between the host and keyboard firmware.

**Acceptance Criteria:**

**Given** `src/data_type.rs` with separate non-macOS and macOS enum variants
**When** the enum is unified
**Then** there is one canonical `DataType` with stable discriminants (`Time = 0xAA … RelayToDevice`)
**And** the macOS-only `Spotify = 0xAE` divergence is reconciled (mapped onto the shared media variants or kept as an explicit, documented platform alias).

**Given** the unified enum
**When** the project is built for Linux, macOS, and Windows
**Then** every target compiles
**And** each provider references the same discriminant values, matching the `hid_data_type` enum documented in the README.

**Given** this is a breaking on-wire change for deployed firmware
**When** it ships
**Then** it lands on or after the SemVer baseline (Story 1.6) and carries the corresponding version bump
**And** the protocol change is called out in the changelog/release notes so firmware authors can update.

**Given** a platform that genuinely lacks a data type
**When** that variant is unused on that platform
**Then** it is gated/handled explicitly rather than by maintaining a separate, drifting enum copy.

### Story 1.8: Replace external curl weather fetch with an in-process HTTP client

As a Linux/macOS user using the weather feature,
I want temperature fetched without shelling out to `curl`,
So that the feature works without an external binary and parses real-world temperatures correctly.

**Acceptance Criteria:**

**Given** `get_weather` shells out to `curl` (`src/providers/weather.rs:12`)
**When** weather is fetched
**Then** an in-process HTTP client performs the request (prefer a lightweight blocking client such as `ureq` over a full async stack, since the call is a single blocking request on its own thread — see stress-test note)
**And** there is no dependency on a system `curl` binary
**And** network/HTTP errors are logged and retried on the next interval rather than panicking.

**Given** a temperature response above 127, below -128, or with a decimal/fractional part
**When** it is parsed (today `parse::<i8>()`, `src/providers/weather.rs:19`)
**Then** the value is parsed without silent failure (wider integer or rounded handling)
**And** the existing `+`, `°`, `C` trimming still works
**And** the Story 1.1 temperature tests are extended to cover these cases.

**Given** the single-byte `Weather` payload (`*value as u8`) sent to the keyboard
**When** the parsing/encoding changes
**Then** any change to the on-wire byte encoding is treated as a breaking protocol change — version-gated behind the SemVer baseline (Story 1.6) and documented for firmware authors
**And** if the encoding can stay single-byte, that compatibility is preserved and stated explicitly.

**Given** the move away from `curl` (which validates TLS certificates by default)
**When** the in-process HTTP client is configured
**Then** requests use HTTPS with certificate validation enabled — the security posture must not regress (a plain-`http://` or unverified-TLS fetch would let a network attacker set the temperature byte written to the HID device)
**And** the weather URL/response is treated as untrusted input.

**Given** the new HTTP/TLS dependency tree introduced by this story
**When** the dependencies are added
**Then** `cargo audit` (or equivalent advisory scan) runs in the `test.yml` CI
**And** the job fails on a known-vulnerable dependency, so the swap from "external binary" to "crate tree" does not trade one supply-chain risk for an unaudited one.
