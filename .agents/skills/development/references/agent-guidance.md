<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Agent guidance architecture

`AGENTS.md` is a routing and invariant layer, not a handbook. Skills are domain
routers. References carry conditional detail. Keep each layer cheap enough that
an agent loads only what changes its decision.

## Three-stage disclosure

1. `AGENTS.md`: project identity, universal invariants, mandatory skill routing,
   the basic change loop, and common commands.
2. `SKILL.md`: domain purpose, core workflow, non-negotiable rules, and explicit
   conditions for loading each reference.
3. `references/`: one focused topic per file—architecture, provider contract,
   test strategy, diagnostic procedure, or source-dated baseline.

The hard limit is 150 physical lines for `AGENTS.md` and every text instruction,
reference, or helper under `.agents/skills`. A limit is not a target. Split by
decision boundary before 150 lines; do not compress unrelated subjects into
dense prose to game the count.

## Routing rules

- Skill descriptions contain only concrete trigger conditions and start with
  `Use when...`; workflow belongs in the body.
- Project-local skill names do not repeat `voice-activation`; the repository
  already supplies that context.
- Every project skill appears in the root routing table.
- Every reference is linked from its `SKILL.md` with the exact condition that
  requires it. Avoid “read everything first.”
- Keep shared rules in one owner. Cross-reference another skill by name instead
  of copying its workflow.
- Source-dated compatibility facts live in a baseline reference and say how to
  refresh them.
- Scripts encapsulate reusable deterministic work. Split helpers by
  responsibility when they approach the same line limit.

## Editing guidance

1. Run `make check-agent-guidance` first and observe the relevant baseline
   failure for a structure change.
2. Map every removed root section to an owning skill/reference; discard only
   duplication or generic advice that does not change decisions.
3. Update the root router and affected skill routes together.
4. Validate each changed skill with the bundled `quick_validate.py`.
5. Run `make check`, reference-routing checks, and `git diff --check`.

Use the external `skill-creator` and `superpowers:writing-skills` skills when
creating or substantially changing project skills. Keep automatic discovery
unless the user explicitly requests explicit-only invocation.

## Record lessons, not session history

A reusable failure note has four parts:

1. **Symptom:** what a user or test can observe and search for.
2. **Verified cause:** the ownership or lifecycle invariant that actually broke.
3. **Decisive evidence:** the log boundary, crash frame, state transition, or
   failing regression that separated the cause from plausible alternatives.
4. **Guardrail:** the production rule and focused test that prevent recurrence.

Put the case in the reference that owns the decision. Promote only the shortest
cross-domain lesson to `AGENTS.md`. Do not store raw logs, prompts, transcripts,
credentials, machine-specific inventory, transient timings, or a chronological
retelling. Merge a new case into an existing rule when it teaches the same
decision; more scars are not automatically more wisdom.

## Failure smells

- Root instructions explain subsystem mechanics instead of routing to them.
- A skill requires every reference for every task.
- Two references define the same invariant with slightly different wording.
- A reference is not linked, has no load condition, or exceeds 150 lines.
- The line check passes only because paragraphs became unreadably dense.
