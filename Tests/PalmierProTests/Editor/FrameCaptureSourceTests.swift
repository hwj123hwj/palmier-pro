import Testing
@testable import PalmierPro

@Suite("FrameCaptureSource.timelineCapture")
struct FrameCaptureSourceTests {
    @Test(arguments: [
        (720, 720, 719),
        (0, 720, 0),
        (100, 720, 100),
        (719, 720, 719),
        (0, 0, 0),
    ])
    func playheadResolvesToARealFrame(playhead: Int, totalFrames: Int, expected: Int) {
        guard case .timeline(let frame) = FrameCaptureSource.timelineCapture(
            playhead: playhead, totalFrames: totalFrames
        ) else {
            Issue.record("expected a timeline source"); return
        }
        #expect(frame == expected)
    }
}
