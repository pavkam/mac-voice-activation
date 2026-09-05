#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

"""Send one initialize request to an ACP process and print bounded metadata."""

import json
import os
import selectors
import signal
import subprocess
import sys


def terminate(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)


def summarize(result: dict[str, object]) -> dict[str, object]:
    info = result.get("agentInfo")
    info = info if isinstance(info, dict) else {}
    methods = result.get("authMethods")
    methods = methods if isinstance(methods, list) else []
    capabilities = result.get("agentCapabilities")
    capabilities = capabilities if isinstance(capabilities, dict) else {}
    return {
        "protocolVersion": result.get("protocolVersion"),
        "agent": {
            key: info[key]
            for key in ("name", "title", "version")
            if isinstance(info.get(key), str)
        },
        "authMethods": [
            item["name"]
            for item in methods
            if isinstance(item, dict) and isinstance(item.get("name"), str)
        ],
        "capabilityKeys": sorted(capabilities.keys()),
    }


def main(command: list[str]) -> None:
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": 1,
            "clientCapabilities": {},
            "clientInfo": {
                "name": "voice-activation-compatibility-probe",
                "title": "Voice Activation compatibility probe",
                "version": "1",
            },
        },
    }
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        start_new_session=True,
    )
    try:
        assert process.stdin is not None
        assert process.stdout is not None
        process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=20):
            raise RuntimeError("timed out waiting for initialize response")
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("ACP process closed stdout before initialize response")
        if len(line.encode("utf-8")) > 1_048_576:
            raise RuntimeError("initialize response exceeded the 1 MiB frame limit")
        message = json.loads(line)
        if message.get("id") != 1:
            raise RuntimeError("first response did not preserve request id 1")
        if "error" in message:
            error = message["error"]
            code = error.get("code") if isinstance(error, dict) else "unknown"
            raise RuntimeError(f"initialize returned JSON-RPC error {code}")
        result = message.get("result")
        if not isinstance(result, dict):
            raise RuntimeError("initialize result was not an object")
        print(json.dumps(summarize(result), indent=2, sort_keys=True))
    finally:
        terminate(process)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: probe-initialize.py COMMAND [ARG ...]")
    main(sys.argv[1:])
