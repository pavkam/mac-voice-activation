import CoreGraphics

enum MenuProfileListLayout {
    private static let rowHeight: CGFloat = 50
    private static let rowSpacing: CGFloat = 7
    private static let maximumHeight: CGFloat = 360

    static func height(profileCount: Int) -> CGFloat {
        let count = max(0, profileCount)
        guard count > 0 else { return 0 }

        let contentHeight = CGFloat(count) * rowHeight
            + CGFloat(count - 1) * rowSpacing
        return min(contentHeight, maximumHeight)
    }
}
