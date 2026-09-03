import Testing
@testable import VoiceActivationApp

struct AgentExecutableLocatorTests {
    @Test func locate_WhenSeveralNpxVersionsExist_UsesNewestExecutableVersion() {
        let executable = "/Users/test/.nvm/versions/node/v20.10.0/bin/npx"
        let locator = AgentExecutableLocator(
            path: nil,
            additionalDirectories: [],
            nvmBinDirectories: [
                "/Users/test/.nvm/versions/node/v20.9.0/bin",
                "/Users/test/.nvm/versions/node/v20.10.0/bin",
                "/Users/test/.nvm/versions/node/v18.20.4/bin",
            ],
            isExecutableFile: { $0.hasSuffix("/npx") })

        #expect(locator.locate(executable: "npx") == executable)
    }

    @Test func locate_WhenNoCandidateIsExecutable_ReturnsNil() {
        let locator = AgentExecutableLocator(
            path: "/opt/homebrew/bin:/usr/local/bin",
            additionalDirectories: ["/Applications/ChatGPT.app/Contents/Resources"],
            nvmBinDirectories: ["/Users/test/.nvm/versions/node/v22.0.0/bin"],
            isExecutableFile: { _ in false })

        #expect(locator.locate(executable: "npx") == nil)
    }

    @Test func locate_WhenPathContainsSeveralCandidates_UsesExplicitPathPrecedence() {
        let preferred = "/custom/first/cursor-agent"
        let candidates = Set([
            preferred,
            "/custom/second/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
        ])
        let locator = AgentExecutableLocator(
            path: "/custom/first:/custom/second",
            additionalDirectories: ["/opt/homebrew/bin"],
            nvmBinDirectories: [],
            isExecutableFile: { candidates.contains($0) })

        #expect(locator.locate(executable: "cursor-agent") == preferred)
    }

    @Test func locate_WhenPathContainsEmptyAndRelativeEntries_SkipsThem() {
        let absolute = "/absolute/bin/npx"
        let locator = AgentExecutableLocator(
            path: ":relative/bin::/absolute/bin",
            additionalDirectories: [],
            nvmBinDirectories: [],
            isExecutableFile: { $0 == "npx" || $0 == "relative/bin/npx" || $0 == absolute })

        #expect(locator.locate(executable: "npx") == absolute)
    }

    @Test func locate_WhenNewestNvmCandidateIsNotExecutable_UsesNextExecutableVersion() {
        let executable = "/Users/test/.nvm/versions/node/v20.10.0/bin/npx"
        let locator = AgentExecutableLocator(
            path: nil,
            additionalDirectories: [],
            nvmBinDirectories: [
                "/Users/test/.nvm/versions/node/v22.0.0/bin",
                "/Users/test/.nvm/versions/node/v20.10.0/bin",
            ],
            isExecutableFile: { $0 == executable })

        #expect(locator.locate(executable: "npx") == executable)
    }

    @Test func locate_WhenInjectedDirectoryIsRelative_NeverReturnsRelativeCandidate() {
        let locator = AgentExecutableLocator(
            path: nil,
            additionalDirectories: ["relative/bin"],
            nvmBinDirectories: [],
            isExecutableFile: { _ in true })

        #expect(locator.locate(executable: "npx") == nil)
    }
}
