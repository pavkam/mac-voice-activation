import Foundation
import Testing
@testable import VoiceActivationCore

struct ACPLineFramerTests {
    @Test func append_WhenTwoFramesShareAChunk_ReturnsBothFrames() throws {
        var framer = ACPLineFramer()

        let frames = try framer.append(Data("{\"first\":1}\n{\"second\":2}\n".utf8))

        #expect(frames == [
            Data("{\"first\":1}".utf8),
            Data("{\"second\":2}".utf8),
        ])
    }

    @Test func append_WhenMultibyteFrameIsSplitAtEveryByte_ReassemblesUTF8() throws {
        let line = Data("{\"text\":\"Olá 👋\"}\n".utf8)
        let expectedFrame = Data("{\"text\":\"Olá 👋\"}".utf8)

        for splitIndex in 0 ... line.count {
            var framer = ACPLineFramer()
            let firstFrames = try framer.append(line.prefix(splitIndex))
            let secondFrames = try framer.append(line.dropFirst(splitIndex))

            #expect(firstFrames + secondFrames == [expectedFrame])
            try framer.finish()
        }
    }

    @Test func append_WhenFrameExceedsOneMiB_ThrowsOversizedFrame() {
        var framer = ACPLineFramer()
        let oversizedFrame = Data(
            repeating: 0x61,
            count: ACPLineFramer.maximumFrameBytes + 1)

        #expect(throws: ACPLineFramer.FramingError.oversizedFrame) {
            try framer.append(oversizedFrame)
        }
    }

    @Test func finish_WhenTrailingBytesLackNewline_ThrowsIncompleteFrame() throws {
        var framer = ACPLineFramer()
        _ = try framer.append(Data("{\"unfinished\":true}".utf8))

        #expect(throws: ACPLineFramer.FramingError.incompleteFrame) {
            try framer.finish()
        }
    }
}
