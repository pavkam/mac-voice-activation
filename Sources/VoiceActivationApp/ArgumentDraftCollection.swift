// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Foundation

struct ArgumentDraftCollection: Equatable {
    var rows: [ArgumentDraft]

    var values: [String] {
        rows.map(\.value)
    }

    init(values: [String]) {
        rows = values.map { ArgumentDraft(value: $0) }
    }

    mutating func replace(with values: [String]) {
        self = ArgumentDraftCollection(values: values)
    }

    mutating func append() {
        rows.append(ArgumentDraft(value: ""))
    }

    mutating func remove(id: UUID) {
        rows.removeAll { $0.id == id }
    }

    static func == (lhs: ArgumentDraftCollection, rhs: ArgumentDraftCollection) -> Bool {
        lhs.values == rhs.values
    }
}
