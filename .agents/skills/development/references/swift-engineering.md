<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Swift engineering

## API and type design

- Match four-space indentation and local wrapping. Do not mechanically format
  unrelated files; the repository has no global formatter.
- Optimize names at the call site: verbs for effects, nouns for values,
  `UpperCamelCase` types, and `lowerCamelCase` members/cases.
- Prefer immutable structs/enums. Use `final` classes for identity, framework
  delegation, or shared lifetime; use actors for cross-domain mutable state.
- Keep access narrow and use explicit `any Protocol` existentials.
- Prefer typed errors and exhaustive switches over sentinel strings or related
  booleans that permit invalid states.
- Avoid runtime `fatalError`, force unwraps, `try!`, and unexplained `try?`.
- Stored/framework callbacks use weak capture when their owner may be retained.
- Comments explain ownership, invariants, bounds, concurrency, or surprising
  failure policy—not syntax.

## Swift 6 concurrency

- Mark coordinator/UI ownership `@MainActor`; do not hide isolation problems
  behind `DispatchQueue.main.async`.
- Values crossing actors or `@Sendable` closures must be genuinely `Sendable`.
  `@unchecked Sendable` requires a documented lock, queue, or immutability proof.
- Prefer structured tasks. Store unstructured task handles that outlive a
  method, cancel on replacement/shutdown, and guard results with identity.
- Use `Task.detached` only when work must not inherit actor isolation and has an
  explicit owner.
- Check cancellation before expensive work and after suspension points where a
  stale result could escape. Use cancellation handlers for external resources.
- Resume continuations exactly once on success, failure, and cancellation.
- Never hold a lock across `await` or invoke unknown code while holding one.
- Synchronous foreign APIs and blocking I/O remain blocking inside `async`.
  Follow existing dedicated-queue + checked-continuation adapters.
- Preserve ordered backpressure; independent fire-and-forget tasks are not an
  event-delivery strategy.

## SwiftUI and AppKit

- Keep `body` declarative and cheap. No blocking I/O, network, process launch,
  or durable mutation during view construction.
- Keep one authoritative model state. View-local state is only for truly
  transient presentation.
- Mark non-observed dependencies and task handles on `@Observable` types with
  `@ObservationIgnored`.
- Preserve stable identity for profiles, timeline entries, tools, and
  permissions. Array indices are not domain identity.
- Window behavior stays in presenters/controllers. Test semantic mapping and
  geometry before opening real windows.
- Preserve accessibility labels, keyboard use, Reduce Motion, contrast, and
  non-audio/non-color state cues.

## Files and public documentation

- Swift files under `Sources/` and `Tests/` have a 700-line hard limit.
- Split a stateful type with `Type+Responsibility.swift` extensions when state
  ownership should remain together. Extract a helper only for a real invariant,
  lifecycle, synchronization boundary, or independently testable policy.
- Every public `VoiceActivationCore` declaration needs useful `///` DocC,
  including cases and members. Describe intent, ownership, side effects, bounds,
  and failure behavior.

Primary references: [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/),
[Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/),
and [Swift Testing](https://developer.apple.com/documentation/testing).
