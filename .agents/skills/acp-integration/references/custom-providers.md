<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Custom ACP providers

A custom profile is an escape hatch, not a weaker protocol boundary.

## Required contract

- Persist an absolute executable path and explicit argument array.
- Launch directly with `Foundation.Process`; never use a shell or interpret
  provider-supplied strings as command syntax.
- Require ACP protocol version 1, newline-delimited JSON-RPC on stdio, and
  protocol-only stdout.
- Use an absolute working directory.
- Treat credentials as provider-owned ambient state. Do not copy tokens into
  app preferences, launch arguments, fixtures, or diagnostics.
- Gate optional methods by negotiated capabilities. Unknown extensions remain
  bounded diagnostics or method-not-found responses.
- Apply the same frame, identifier, prompt, queue, permission, stderr, session,
  and cache bounds as built-in providers.

## Compatibility checklist

Before documenting a custom provider as compatible, capture source-dated
evidence for:

1. the exact executable and version;
2. its ACP transport and protocol version;
3. an initialize response and advertised capabilities;
4. authentication behavior without recording credentials;
5. session creation and cancellation behavior;
6. permission option and cancellation shapes;
7. output, stderr, process-exit, and malformed-frame behavior; and
8. deterministic fixtures covering any provider-specific payloads.

An initialize-only handshake proves framing and basic negotiation, not prompt,
permission, tool, or cancellation compatibility. Do not promote a custom client
to a built-in preset on handshake evidence alone.
