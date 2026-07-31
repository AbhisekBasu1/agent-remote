import Foundation
import Testing
@testable import DualSenseBridgeCore

struct MicrophoneInputTapTests {
    private func record(
        _ tap: inout DualSenseMicrophoneInputTap,
        timestampNanos: UInt64,
        report: [UInt8],
        reportID: UInt32 = 0x31
    ) {
        report.withUnsafeBufferPointer {
            tap.record(
                timestampNanos: timestampNanos,
                reportID: reportID,
                bytes: $0
            )
        }
    }

    private func microphoneReport(counter: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[1] = 0x02 // microphone feedback flag
        report[2] = counter
        report[3] = 0xd4
        return report
    }

    private func gamepadReport(sequence: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[8] = sequence // Sony input sequence at common offset 6
        return report
    }

    /// A 100 Hz controller stream received at 44.5 Hz shows counter deltas of
    /// about +2 and an estimated generation rate near double the arrival
    /// rate. That distinction is the entire point of the tap.
    @Test func halvedStreamShowsCounterGapsAndDoubledGenerationRate() {
        var tap = DualSenseMicrophoneInputTap()
        tap.begin()

        let base: UInt64 = 1_000_000_000
        let intervalNanos: UInt64 = 22_500_000 // 22.5 ms arrivals
        for index in 0..<41 {
            record(
                &tap,
                timestampNanos: base + UInt64(index) * intervalNanos,
                report: microphoneReport(counter: UInt8((index * 2) & 0xff))
            )
        }
        for index in 0..<10 {
            record(
                &tap,
                timestampNanos: base + UInt64(index) * 90_000_000,
                report: gamepadReport(sequence: UInt8(index))
            )
        }
        record(
            &tap,
            timestampNanos: base,
            report: [0x05, 0x00, 0x00],
            reportID: 0x05
        )

        let summary = tap.finish()
        #expect(summary.microphoneCount == 41)
        #expect(summary.gamepadCount == 10)
        #expect(summary.otherCount == 1)
        #expect(summary.countsByReportID[0x31] == 51)
        #expect(summary.countsByReportID[0x05] == 1)
        #expect(summary.flagByteHistogram[0x02] == 41)
        #expect(summary.flagByteHistogram[0x00] == 10)

        let mic = summary.microphoneCounter
        #expect(mic.sampleCount == 41)
        #expect(mic.deltaHistogram[2] == 40)
        #expect(mic.missed == 40)
        #expect(mic.duplicates == 0)
        #expect(mic.backwards == 0)

        let received = try! #require(mic.receivedPerSecond)
        let generated = try! #require(mic.estimatedGeneratedPerSecond)
        #expect(abs(received - 44.4) < 0.5)
        #expect(abs(generated - 2 * received) < 0.5)

        let gamepad = summary.gamepadSequence
        #expect(gamepad.deltaHistogram[1] == 9)
        #expect(gamepad.missed == 0)

        let interval = try! #require(summary.microphoneInterArrival)
        #expect(abs(interval.p50Ms - 22.5) < 0.2)
        #expect(interval.burstsUnder2Ms == 0)
        #expect(interval.histogramMs[22] == 40 || interval.histogramMs[23] == 40)
    }

    @Test func counterWrapDuplicatesAndBackwardsAreClassified() {
        var tap = DualSenseMicrophoneInputTap()
        tap.begin()

        let counters: [UInt8] = [254, 255, 0, 0, 3, 1]
        for (index, counter) in counters.enumerated() {
            record(
                &tap,
                timestampNanos: 1_000_000 + UInt64(index) * 10_000_000,
                report: microphoneReport(counter: counter)
            )
        }

        let mic = tap.finish().microphoneCounter
        #expect(mic.deltaHistogram[1] == 2) // 254→255, 255→0
        #expect(mic.deltaHistogram[0] == 1) // 0→0 duplicate
        #expect(mic.deltaHistogram[3] == 1) // 0→3, two missing
        #expect(mic.duplicates == 1)
        #expect(mic.missed == 2)
        #expect(mic.backwards == 1) // 3→1
    }

    /// Mirrors the live 15 ms-quantized sessions: the controller numbers mic
    /// packets at ~100 Hz (byte-2 gaps on arrival) but stamps every
    /// transmitted 0x31 report with a shared rolling high nibble. A
    /// contiguous combined nibble with a gapped mic counter proves the loss
    /// happens inside the controller before transmission, not in macOS.
    @Test func contiguousTransportNibbleWithGappedMicCounterIsDetected() {
        var tap = DualSenseMicrophoneInputTap()
        tap.begin()

        var nibble: UInt8 = 0
        var micCounter: UInt8 = 0
        var nanos: UInt64 = 1_000_000_000
        for step in 0..<60 {
            let isMic = step % 3 != 2 // two mic reports, then one gamepad
            if isMic {
                var report = microphoneReport(counter: micCounter)
                report[1] = (nibble << 4) | 0x02
                micCounter &+= step % 3 == 0 ? 3 : 2 // ~100 Hz production
                record(&tap, timestampNanos: nanos, report: report)
            } else {
                var report = gamepadReport(sequence: 1)
                report[1] = (nibble << 4) | 0x01
                record(&tap, timestampNanos: nanos, report: report)
            }
            nibble = (nibble &+ 1) & 0x0f
            nanos += 15_000_000
        }

        let summary = tap.finish()
        #expect(summary.combinedTransportNibble.missed == 0)
        #expect(summary.combinedTransportNibble.duplicates == 0)
        #expect(summary.combinedTransportNibble.deltaHistogram[1] == 59)
        #expect(summary.microphoneCounter.missed > 0)

        // Per-class nibble sequences skip the other class's reports, so they
        // gap even though the combined transport sequence is complete.
        #expect(summary.microphoneTransportNibble.missed > 0)
    }

    @Test func recordingStopsAtCapacityAndReportsTruncation() {
        var tap = DualSenseMicrophoneInputTap(capacity: 16)
        tap.begin()
        for index in 0..<20 {
            record(
                &tap,
                timestampNanos: UInt64(index + 1) * 1_000_000,
                report: microphoneReport(counter: UInt8(index))
            )
        }
        let summary = tap.finish()
        #expect(summary.recordCount == 16)
        #expect(summary.truncated)
    }

    @Test func summaryLinesContainTheDecisiveNumbers() {
        var tap = DualSenseMicrophoneInputTap()
        tap.begin()
        for index in 0..<11 {
            record(
                &tap,
                timestampNanos: 1_000_000 + UInt64(index) * 22_500_000,
                report: microphoneReport(counter: UInt8(index * 2))
            )
        }
        let lines = DualSenseMicrophoneInputTap.summaryLines(tap.finish())
        #expect(lines.contains { $0.contains("mic input tap classes: mic=11") })
        #expect(lines.contains { $0.contains("missed=10") })
        #expect(lines.contains { $0.contains("estimatedGenerated=") })
    }
}
