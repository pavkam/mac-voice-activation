// SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
// SPDX-License-Identifier: MIT

import Observation

@MainActor
@Observable
final class ActionFeedbackOverlayModel {
    /// The moment being shown, or `nil` while the surface is empty.
    var presentation: ActionFeedbackPresentation?
}
