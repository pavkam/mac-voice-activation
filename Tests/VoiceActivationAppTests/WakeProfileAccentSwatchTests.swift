import AppKit
import Testing
import VoiceActivationCore
@testable import VoiceActivationApp

struct WakeProfileAccentSwatchTests {
    @MainActor @Test(arguments: WakeProfileAccent.allCases)
    func image_WhenRendered_PreservesItsColor(accent: WakeProfileAccent) throws {
        let image = WakeProfileAccentSwatch.image(for: accent)
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let sampled = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let color = try #require(sampled.usingColorSpace(.sRGB))
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]

        #expect(!image.isTemplate)
        #expect((channels.max() ?? 0) - (channels.min() ?? 0) > 0.2)
    }
}
