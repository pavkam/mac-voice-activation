<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Accessibility, performance, and validation

Accessibility settings are supported states, not a screenshot checklist at the
end. Define them with the interaction before choosing an effect.

## Accessibility contract

- Read `accessibilityReduceMotion`, `accessibilityReduceTransparency`,
  `accessibilityDifferentiateWithoutColor`, and `colorSchemeContrast` in
  SwiftUI when the surface depends on them.
- At AppKit boundaries, use the matching `NSWorkspace` display preferences and
  observe `accessibilityDisplayOptionsDidChangeNotification` when cached.
- Replace spatial, scaling, blur, and repeating motion with opacity or a static
  state under Reduce Motion.
- Use opaque semantic backgrounds under Reduce Transparency.
- Provide symbols, labels, shape, or copy in addition to color and sound.
- Give every custom action an accessibility label; add a value for stateful
  controls and a help string for compact icon buttons.
- Hide decorative gradients, orbs, separators, and marks from accessibility.
- Preserve logical VoiceOver order and group content that forms one status.
- Keep standard keyboard shortcuts and default/cancel actions. A regular window
  supports Full Keyboard Access; a non-activating panel must not steal focus to
  fake keyboard support.
- Avoid timed auto-dismiss for content that requires reading or action.

## Performance contract

`body` and animation closures are rendering code. They do not launch processes,
read files, access Keychain, call a network service, or create unbounded tasks.
Keep expensive Markdown reduction and presentation normalization outside view
construction.

Streaming state already coalesces visible publication to a bounded cadence.
Preserve that boundary, stable IDs, ordered delivery, and user-controlled scroll
position. An animation must not break backpressure or make a stale run visible.

Use Instruments when the complaint is frame rate, CPU, recomposition, or memory.
Measure the release app with representative streaming output; do not optimize a
static preview and call it performance work.

## Automated test layers

1. **Presentation:** pure tests for phase → copy, symbol, color role, action, and
   accessibility value.
2. **Layout:** pure geometry tests for compact/expanded sizes, negative display
   origins, clamping, relocation, minimize/restore, and transcript shape.
3. **Motion policy:** pure tests for durations and Reduce Motion substitutions.
4. **Presenter/controller:** main-actor tests for stale IDs, idempotent actions,
   panel visibility, saved placement, and `canBecomeKey`/`canBecomeMain`.
5. **Rendered transition:** an isolated AppKit-hosted test only when intermediate
   visual state is the behavior. Assert before, during, and settled output with
   bounded waits; never test that a private modifier exists.

Use Swift Testing and silent audio adapters. Tests do not open visible windows,
play sounds, contact providers, wait on real speech, or depend on the user's
accessibility settings. Inject or pass the preference into pure policies.

## Battle-tested UI regressions

| Symptom | Verified cause | Guardrail |
| --- | --- | --- |
| The elapsed clock keeps advancing while the conversation waits for a follow-up | The presentation ticker stopped, but `TimelineView` still treated every nonterminal phase as active | Give the phase one `advancesElapsedTime` predicate, stop publication at turn completion, render a static value while listening, and reset the live start date without counting idle time. |
| Footer buttons snap or unrelated content drifts when phase changes | Animation was attached above the causal state or conditional children had no transition | Transition the inserted/removed action groups, scope `.animation(..., value: phase)`, and substitute opacity under Reduce Motion. |
| An animation test passes alone but the full suite crashes in AppKit teardown | A real `NSWindow` shared process-global AppKit animation state with parallel tests | Keep pure motion tests in-process; isolate the one intermediate-pixel window test in a child process and propagate sanitizer runtimes. |
| Menu profile rows disappear despite valid model data | `MenuBarExtra` proposed an unusable height and the view accepted it | Put fallback sizing in a pure layout policy and render-test the zero/unspecified-height proposal. |
| Streaming output follows until the user scrolls, then either fights them or never resumes | Auto-follow was keyed only to content updates | Track distance from bottom and user scrolling separately; follow growth only while the viewport was already at the bottom. |
| A floating panel steals focus, appears behind the current app, or cannot drag | SwiftUI content tried to own AppKit activation/frame behavior | Keep `NSPanel` non-activating, order it explicitly, and route drag/minimize/restore through the controller while preserving the expanded frame. |

## Manual experience matrix

For a user-visible change, build the real bundle with `CONFIGURATION=debug make
app` and exercise the affected flow in proportion to risk:

- light and dark appearance;
- Increase Contrast and Differentiate Without Color;
- Reduce Motion and Reduce Transparency;
- VoiceOver labels/order and Full Keyboard Access where applicable;
- muted audio and reply narration enabled;
- menu open, panel dragging, event tracking, and modal Settings work;
- multiple displays, negative origins, resolution changes, and removed screens;
- short, long, empty, rapidly streaming, error, and permission content; and
- appearance while another app remains active.

Use Accessibility Inspector for labels, roles, values, contrast, and grouping.
Use Instruments' SwiftUI, Time Profiler, Hangs, and Allocations templates when a
change affects rendering cadence or lifetime.

## Completion commands

Run the focused test first, then the proportional baseline:

```bash
swift test --filter <ExactSuiteOrTest>
swift test
make app
make check
git diff --check
```

Add `swift test --sanitize=thread` for main-actor bridging, callbacks, animated
publication, scroll tracking, timers, or panel lifecycle. Report any manual
matrix row not exercised; “looks slick” is not verification evidence.
