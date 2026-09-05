#!/usr/bin/env swift

// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

let projectDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dump = Process()
dump.executableURL = URL(fileURLWithPath: "/usr/bin/env")
dump.arguments = [
    "swift",
    "package",
    "dump-symbol-graph",
    "--minimum-access-level", "public",
    "--skip-synthesized-members",
    "--skip-inherited-docs",
]
dump.currentDirectoryURL = projectDirectory
try dump.run()
dump.waitUntilExit()

guard dump.terminationReason == .exit, dump.terminationStatus == 0 else {
    fputs("Could not generate the public Swift symbol graph.\n", stderr)
    exit(1)
}

let buildDirectory = projectDirectory.appending(path: ".build", directoryHint: .isDirectory)
guard let enumerator = FileManager.default.enumerator(
    at: buildDirectory,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles])
else {
    fputs("Could not inspect the Swift build directory.\n", stderr)
    exit(1)
}

let graphURL = enumerator.compactMap { $0 as? URL }.first {
    $0.lastPathComponent == "VoiceActivationCore.symbols.json"
        && $0.deletingLastPathComponent().lastPathComponent == "symbolgraph"
}
guard let graphURL else {
    fputs("VoiceActivationCore public symbol graph was not generated.\n", stderr)
    exit(1)
}

let data = try Data(contentsOf: graphURL)
guard let graph = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let symbols = graph["symbols"] as? [[String: Any]]
else {
    fputs("VoiceActivationCore public symbol graph has an unexpected format.\n", stderr)
    exit(1)
}

let undocumented = symbols.compactMap { symbol -> String? in
    guard symbol["docComment"] == nil else { return nil }
    let components = symbol["pathComponents"] as? [String] ?? ["<unknown symbol>"]
    let location = symbol["location"] as? [String: Any]
    let uri = location?["uri"] as? String ?? ""
    // RawRepresentable and synthesized Codable entry points can remain in the
    // graph even with --skip-synthesized-members. They have no source location
    // at which a documentation comment could be written.
    guard !uri.isEmpty else { return nil }
    let position = location?["position"] as? [String: Any]
    let zeroBasedLine = position?["line"] as? Int ?? 0
    let fileName = URL(string: uri)?.lastPathComponent ?? uri
    return "\(fileName):\(zeroBasedLine + 1): \(components.joined(separator: "."))"
}.sorted()

guard undocumented.isEmpty else {
    for symbol in undocumented {
        fputs("Undocumented public Swift symbol: \(symbol)\n", stderr)
    }
    exit(1)
}

print("Swift documentation verified: every public VoiceActivationCore symbol has DocC comments.")
