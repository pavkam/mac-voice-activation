<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# ACP v1 and Voice Activation

Validated against the stable ACP v1 documentation on 2026-09-05.

## Wire and lifecycle

Voice Activation is the ACP client. Cursor or an adapter process is the ACP
agent. Communication is UTF-8 JSON-RPC 2.0 over child-process stdin and stdout,
with one compact JSON value per line. A protocol line cannot contain a literal
newline. Stdout is protocol-only; stderr is a separate diagnostic stream.

The supported lifecycle is:

1. `initialize` with `protocolVersion: 1`, empty `clientCapabilities`, and
   client metadata.
2. `session/new` with an absolute `cwd` and `mcpServers: []`.
3. One `session/prompt` at a time in the current session.
4. Ordered `session/update` notifications until the prompt response supplies a
   stop reason.
5. `session/cancel` for authoritative cancellation.
6. `session/request_permission` responses that return the agent's exact option
   identifier or a cancelled outcome.

The app relies on ambient provider authentication. It does not currently issue
`authenticate`. A `session/new` JSON-RPC error with code `-32000` is mapped to
provider authentication guidance.

ACP capabilities are negotiated during initialization. An omitted capability
means unsupported. The stable baseline includes text and resource-link prompt
content plus session creation, prompt, cancel, and updates; optional loading,
terminal, filesystem, MCP, elicitation, and authentication features must be
gated by the advertised capability before use.

## Project implementation contract

- `ACPLineFramer` rejects frames over 1 MiB.
- `ACPMessage` and `ACPJSONValue` preserve JSON-RPC IDs as `int64`, string, or
  null. Never round-trip them through a floating-point value.
- `ACPClientConnection` accepts protocol version 1 only and routes updates only
  for its current session ID.
- `ACPEventDecoder` handles `user_message_chunk`, `agent_message_chunk`,
  `agent_thought_chunk`, `tool_call`, `tool_call_update`, `plan`,
  `available_commands_update`, `current_mode_update`, `config_option_update`,
  `session_info_update`, and `usage_update`.
- Unknown updates become bounded diagnostics. Unknown inbound requests receive
  JSON-RPC method-not-found.
- Cursor blocking requests `cursor/ask_question` and `cursor/create_plan`
  receive cancelled results so the provider cannot wait forever.
- `ACPProcessTransport` launches an absolute executable directly with an
  argument array. Do not introduce a shell.
- A missing session may be recreated and the prompt retried once only before
  output, permissions, or other observable activity. Activity forbids replay.

The profile system prompt is placed in Codex `CODEX_CONFIG` as
`developer_instructions`, preserving other object keys. ACP v1 has no portable
system-role field; other providers receive the instruction in a separate text
block.

## Primary sources

- [ACP v1 overview](https://agentclientprotocol.com/protocol/v1/overview)
- [ACP transports](https://agentclientprotocol.com/protocol/v1/transports)
- [Initialization](https://agentclientprotocol.com/protocol/v1/initialization)
- [Session setup](https://agentclientprotocol.com/protocol/v1/session-setup)
- [Prompt turns](https://agentclientprotocol.com/protocol/v1/prompt-turn)
- [Tool calls and permissions](https://agentclientprotocol.com/protocol/v1/tool-calls)
