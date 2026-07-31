import Testing
@testable import DualSenseBridgeCore

@Test func gapSmootherRemovesHardSignalToSilenceEdges() {
    var smoother = DualSensePCMGapSmoother(fadeFrames: 96)

    // Let the initial fade-in finish, then establish a steady signal.
    var output: [Int16] = []
    for _ in 0..<120 {
        output.append(smoother.render(12_000))
    }
    for _ in 0..<120 {
        output.append(smoother.render(nil))
    }
    for _ in 0..<120 {
        output.append(smoother.render(-12_000))
    }

    var maximumStep = 0
    for index in 1..<output.count {
        maximumStep = max(
            maximumStep,
            abs(Int(output[index]) - Int(output[index - 1]))
        )
    }
    #expect(maximumStep < 500)
    #expect(output[239] == 0)
    #expect(output.last == -12_000)
}

@Test func gapSmootherLeavesContinuousSignalUntouchedAfterFadeIn() {
    var smoother = DualSensePCMGapSmoother(fadeFrames: 8)
    var output: [Int16] = []
    for value in 1...20 {
        output.append(smoother.render(Int16(value * 100)))
    }

    #expect(output[7] == 800)
    let steadyOutput = Array(output[8...])
    let expectedOutput: [Int16] = (9...20).map { value in
        Int16(value * 100)
    }
    #expect(steadyOutput == expectedOutput)
}
