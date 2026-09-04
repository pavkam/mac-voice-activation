// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

enum AgentExecutableSource: Equatable, Sendable {
    case environmentPath
    case knownLocation
    case nodeVersionManager
    case explicitPath
}

struct AgentExecutableLocation: Equatable, Sendable {
    let path: String
    let source: AgentExecutableSource
}

struct AgentExecutableLocator {
    private let path: String?
    private let additionalDirectories: [String]
    private let nvmBinDirectories: [String]
    private let isExecutableFile: (String) -> Bool

    init(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        additionalDirectories: [String]? = nil,
        nvmBinDirectories: [String]? = nil,
        isExecutableFile: @escaping (String) -> Bool = Self.isExecutableFile)
    {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        self.path = path
        self.additionalDirectories = additionalDirectories ?? [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/ChatGPT.app/Contents/Resources",
            (homeDirectory as NSString).appendingPathComponent(".local/bin"),
        ]
        self.nvmBinDirectories = nvmBinDirectories
            ?? Self.installedNvmBinDirectories(homeDirectory: homeDirectory)
        self.isExecutableFile = isExecutableFile
    }

    func locate(executable: String) -> String? {
        locatedExecutable(named: executable)?.path
    }

    func resolve(executable: String) -> AgentExecutableLocation? {
        if executable.hasPrefix("/") {
            guard isExecutableFile(executable) else { return nil }
            let executableName = (executable as NSString).lastPathComponent
            let discoveredSource = orderedDirectories.first(where: { directory in
                guard directory.path.hasPrefix("/") else { return false }
                return (directory.path as NSString).appendingPathComponent(executableName)
                    == executable
            })?.source
            return AgentExecutableLocation(
                path: executable,
                source: discoveredSource ?? .explicitPath)
        }

        return locatedExecutable(named: executable.trimmingCharacters(
            in: .whitespacesAndNewlines))
    }

    private func locatedExecutable(named executable: String) -> AgentExecutableLocation? {
        guard !executable.isEmpty, !executable.contains("/") else { return nil }

        for directory in orderedDirectories where directory.path.hasPrefix("/") {
            let candidate = (directory.path as NSString).appendingPathComponent(executable)
            guard candidate.hasPrefix("/") else { continue }
            if isExecutableFile(candidate) {
                return AgentExecutableLocation(path: candidate, source: directory.source)
            }
        }
        return nil
    }

    private var orderedDirectories: [(path: String, source: AgentExecutableSource)] {
        let pathDirectories = path?.split(
            separator: ":",
            omittingEmptySubsequences: false).map(String.init) ?? []
        return pathDirectories.map { ($0, .environmentPath) }
            + additionalDirectories.map { ($0, .knownLocation) }
            + nvmBinDirectories.sorted(by: Self.nvmVersionIsNewer).map {
                ($0, .nodeVersionManager)
            }
    }

    private static func installedNvmBinDirectories(homeDirectory: String) -> [String] {
        let nodeVersions = (homeDirectory as NSString)
            .appendingPathComponent(".nvm/versions/node")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: nodeVersions) else {
            return []
        }
        return versions.map {
            (nodeVersions as NSString).appendingPathComponent("\($0)/bin")
        }
    }

    private static func nvmVersionIsNewer(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComponents = nvmVersionComponents(lhs)
        let rhsComponents = nvmVersionComponents(rhs)
        let count = max(lhsComponents.count, rhsComponents.count)
        for index in 0..<count {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return lhs < rhs
    }

    private static func nvmVersionComponents(_ binDirectory: String) -> [Int] {
        let version = URL(fileURLWithPath: binDirectory)
            .deletingLastPathComponent()
            .lastPathComponent
            .drop(while: { $0 == "v" || $0 == "V" })
        return version.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
