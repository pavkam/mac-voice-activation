// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

/// A `UserDefaults` that keeps everything in memory.
///
/// Tests need an isolated defaults store per case, and `UserDefaults(suiteName:)`
/// gives one by writing a plist under `~/Library/Preferences` — a file per test
/// case, left behind for good. Clearing the domain on creation makes each test
/// deterministic but never removes the previous run's file, and the leak
/// compounds: it reached tens of thousands of files here, which is enough that
/// `cfprefsd` stops serving *any* domain, including the app's own. YapOps then
/// read every preference as its default and offered first run on each launch.
///
/// Removing the domains at process exit is not a reliable repair, because the
/// daemon writes a domain that still has pending values when the process
/// disconnects — after the exit handler has already deleted it. Keeping the
/// values in memory means no file is ever created, so there is nothing to race
/// and nothing to clean up.
///
/// Storage is keyed by suite name rather than per instance, because a test may
/// reopen its suite to inspect or seed what the code under test wrote, and two
/// handles on one suite must agree.
final class InMemoryDefaults: UserDefaults {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var suites: [String: [String: Any]] = [:]

    private let suite: String

    /// Returns a suite name unique to this call.
    ///
    /// - Parameter label: A stable prefix identifying the owning test suite.
    static func makeSuiteName(_ label: String) -> String {
        "\(label).\(UUID().uuidString)"
    }

    /// - Parameter suiteName: Names the in-memory store. No domain is
    ///   registered with the preferences daemon, and nothing reaches disk.
    override init?(suiteName: String?) {
        suite = suiteName ?? "__standard__"
        // nil keeps the superclass off any real suite; every accessor below is
        // overridden, so its storage is never consulted.
        super.init(suiteName: nil)
    }

    private func value(_ key: String) -> Any? {
        Self.lock.withLock { Self.suites[suite]?[key] }
    }

    private func store(_ value: Any?, _ key: String) {
        Self.lock.withLock {
            if let value {
                Self.suites[suite, default: [:]][key] = value
            } else {
                _ = Self.suites[suite]?.removeValue(forKey: key)
            }
        }
    }

    override func object(forKey defaultName: String) -> Any? { value(defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { store(value, defaultName) }
    override func removeObject(forKey defaultName: String) { store(nil, defaultName) }

    override func set(_ value: Bool, forKey defaultName: String) { store(value, defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { store(value, defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { store(value, defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { store(value, defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { store(url, defaultName) }

    override func string(forKey defaultName: String) -> String? { value(defaultName) as? String }
    override func data(forKey defaultName: String) -> Data? { value(defaultName) as? Data }
    override func array(forKey defaultName: String) -> [Any]? { value(defaultName) as? [Any] }
    override func stringArray(forKey defaultName: String) -> [String]? {
        value(defaultName) as? [String]
    }

    override func bool(forKey defaultName: String) -> Bool {
        switch value(defaultName) {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: (text as NSString).boolValue
        default: false
        }
    }

    override func integer(forKey defaultName: String) -> Int {
        switch value(defaultName) {
        case let number as NSNumber: number.intValue
        case let text as String: (text as NSString).integerValue
        default: 0
        }
    }

    /// Clears the named store, matching the clean slate call sites expect.
    override func removePersistentDomain(forName domainName: String) {
        Self.lock.withLock { Self.suites[domainName] = [:] }
    }
}
