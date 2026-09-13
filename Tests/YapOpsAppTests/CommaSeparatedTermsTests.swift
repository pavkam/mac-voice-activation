// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import YapOpsApp

struct CommaSeparatedTermsTests {
    @Test func list_SplitsOnCommasAndTrims() {
        #expect(CommaSeparatedTerms.list(" cancel ,stop,  , thank you") == ["cancel", "stop", "thank you"])
    }

    @Test func list_WhenTheLineIsBlank_IsEmpty() {
        #expect(CommaSeparatedTerms.list("   ,  ,").isEmpty)
    }

    @Test func list_IgnoresATrailingCommaMidEdit() {
        #expect(CommaSeparatedTerms.list("cancel, ") == ["cancel"])
    }

    @Test func text_RoundTripsThroughTheList() {
        let terms = ["cancel", "thank you"]

        #expect(CommaSeparatedTerms.list(CommaSeparatedTerms.text(terms)) == terms)
    }
}
