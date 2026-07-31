import Foundation

/// Raw-input instrumentation for one Bluetooth microphone session.
///
/// Records the arrival time and header fields of every IOHID input report
/// into preallocated arrays while the microphone route is active, then
/// computes rate, ordering, and loss statistics after the session ends.
/// Nothing allocates, formats, or writes while packets are arriving, so the
/// tap cannot cause the packet loss it is measuring.
///
/// The decisive fields are the two controller-side generation counters:
/// - microphone feedback carries a rolling packet counter in the byte between
///   the flag byte and the Opus payload;
/// - genuine gamepad reports carry Sony's input sequence counter at offset 6
///   of the common block.
/// Contiguous counters at a low arrival rate mean the controller only
/// produced that many packets under the current outbound state. Counter gaps
/// mean packets were produced but lost before this process saw them.
public struct DualSenseMicrophoneInputTap: Sendable {
    public enum ReportClass: UInt8, Sendable {
        case microphone = 0
        case gamepad = 1
        case other = 2
    }

    public struct CounterAnalysis: Sendable, Equatable {
        /// Records that carried this counter.
        public let sampleCount: Int
        /// Modulo-256 delta histogram between consecutive counter values.
        /// Delta 1 is a contiguous stream; delta 0 is a duplicate; deltas
        /// 2...128 imply (delta - 1) missing packets.
        public let deltaHistogram: [Int: Int]
        /// Total packets implied missing by forward gaps (sum of delta - 1).
        public let missed: Int
        public let duplicates: Int
        /// Deltas above 128 (backwards/reordered counters).
        public let backwards: Int
        /// Received packets per second across this class's observation span.
        public let receivedPerSecond: Double?
        /// (received + missed) per second: the controller's estimated
        /// production rate, independent of delivery losses.
        public let estimatedGeneratedPerSecond: Double?
    }

    public struct IntervalAnalysis: Sendable, Equatable {
        public let minMs: Double
        public let maxMs: Double
        public let meanMs: Double
        public let p50Ms: Double
        public let p95Ms: Double
        /// Consecutive arrivals under 2 ms apart (burst delivery from a
        /// transport that batches packets at fixed service intervals).
        public let burstsUnder2Ms: Int
        /// Inter-arrival histogram in whole-millisecond buckets.
        public let histogramMs: [Int: Int]
    }

    public struct Summary: Sendable {
        public let durationSeconds: Double
        public let recordCount: Int
        public let truncated: Bool
        public let countsByReportID: [UInt32: Int]
        public let microphoneCount: Int
        public let gamepadCount: Int
        public let otherCount: Int
        /// Distinct values of the byte following the 0x31 report ID.
        public let flagByteHistogram: [UInt8: Int]
        public let microphoneCounter: CounterAnalysis
        public let gamepadSequence: CounterAnalysis
        /// The flag byte's high nibble increments once per transmitted 0x31
        /// report and is shared by microphone and gamepad frames. If this
        /// combined modulo-16 sequence is contiguous, every report the
        /// controller radio transmitted reached this process, and any
        /// microphone-counter gaps happened inside the controller before
        /// transmission (link-starvation flushes) — macOS dropped nothing.
        public let combinedTransportNibble: CounterAnalysis
        public let microphoneTransportNibble: CounterAnalysis
        public let gamepadTransportNibble: CounterAnalysis
        public let microphoneInterArrival: IntervalAnalysis?
    }

    private var timestamps: [UInt64]
    private var reportIDs: [UInt32]
    private var lengths: [UInt16]
    private var classes: [UInt8]
    private var flags: [UInt8]
    private var counters: [UInt8]
    private var recordCount = 0
    private var truncated = false
    public private(set) var isActive = false
    public let capacity: Int

    public init(capacity: Int = 32_768) {
        self.capacity = max(capacity, 16)
        timestamps = [UInt64](repeating: 0, count: self.capacity)
        reportIDs = [UInt32](repeating: 0, count: self.capacity)
        lengths = [UInt16](repeating: 0, count: self.capacity)
        classes = [UInt8](repeating: 0, count: self.capacity)
        flags = [UInt8](repeating: 0, count: self.capacity)
        counters = [UInt8](repeating: 0, count: self.capacity)
    }

    public mutating func begin() {
        recordCount = 0
        truncated = false
        isActive = true
    }

    /// Called from the IOHID input-report callback. Constant-time, no
    /// allocation, no formatting, no I/O.
    public mutating func record(
        timestampNanos: UInt64,
        reportID: UInt32,
        bytes: UnsafeBufferPointer<UInt8>
    ) {
        guard isActive else { return }
        guard recordCount < capacity else {
            truncated = true
            return
        }

        let includesReportID = bytes.first == 0x31
        let flagIndex = includesReportID ? 1 : 0
        let flagByte = bytes.count > flagIndex ? bytes[flagIndex] : 0

        let reportClass: ReportClass
        var counter: UInt8 = 0
        if reportID == 0x31, flagByte & 0x02 != 0 {
            reportClass = .microphone
            let counterIndex = flagIndex + 1
            counter = bytes.count > counterIndex ? bytes[counterIndex] : 0
        } else if reportID == 0x31 {
            reportClass = .gamepad
            let sequenceIndex = (includesReportID ? 2 : 1) + 6
            counter = bytes.count > sequenceIndex ? bytes[sequenceIndex] : 0
        } else {
            reportClass = .other
        }

        timestamps[recordCount] = timestampNanos
        reportIDs[recordCount] = reportID
        lengths[recordCount] = UInt16(clamping: bytes.count)
        classes[recordCount] = reportClass.rawValue
        flags[recordCount] = flagByte
        counters[recordCount] = counter
        recordCount += 1
    }

    public mutating func finish() -> Summary {
        isActive = false
        return summary()
    }

    public func summary() -> Summary {
        var countsByReportID: [UInt32: Int] = [:]
        var flagHistogram: [UInt8: Int] = [:]
        var microphoneCount = 0
        var gamepadCount = 0
        var otherCount = 0

        for index in 0..<recordCount {
            countsByReportID[reportIDs[index], default: 0] += 1
            switch ReportClass(rawValue: classes[index]) {
            case .microphone:
                microphoneCount += 1
                flagHistogram[flags[index], default: 0] += 1
            case .gamepad:
                gamepadCount += 1
                flagHistogram[flags[index], default: 0] += 1
            default:
                otherCount += 1
            }
        }

        let duration: Double
        if recordCount >= 2 {
            duration = Double(timestamps[recordCount - 1] &- timestamps[0]) / 1e9
        } else {
            duration = 0
        }

        return Summary(
            durationSeconds: duration,
            recordCount: recordCount,
            truncated: truncated,
            countsByReportID: countsByReportID,
            microphoneCount: microphoneCount,
            gamepadCount: gamepadCount,
            otherCount: otherCount,
            flagByteHistogram: flagHistogram,
            microphoneCounter: counterAnalysis(for: .microphone),
            gamepadSequence: counterAnalysis(for: .gamepad),
            combinedTransportNibble: transportNibbleAnalysis { classValue in
                classValue != ReportClass.other.rawValue
            },
            microphoneTransportNibble: transportNibbleAnalysis { classValue in
                classValue == ReportClass.microphone.rawValue
            },
            gamepadTransportNibble: transportNibbleAnalysis { classValue in
                classValue == ReportClass.gamepad.rawValue
            },
            microphoneInterArrival: intervalAnalysis(for: .microphone)
        )
    }

    /// The formatted diagnostic-log lines for one finished session.
    public static func summaryLines(_ summary: Summary) -> [String] {
        var lines: [String] = []
        let duration = summary.durationSeconds
        func rate(_ count: Int) -> String {
            guard duration > 0 else { return "n/a" }
            return String(format: "%.1f/s", Double(count) / duration)
        }

        lines.append(String(
            format: "mic input tap: duration=%.2fs, records=%d, truncated=%@",
            duration,
            summary.recordCount,
            summary.truncated ? "true" : "false"
        ))

        let idParts = summary.countsByReportID
            .sorted { $0.key < $1.key }
            .map { String(format: "0x%02x=%d (%@)", $0.key, $0.value, rate($0.value)) }
        lines.append("mic input tap report IDs: "
            + (idParts.isEmpty ? "none" : idParts.joined(separator: ", ")))

        lines.append(
            "mic input tap classes: mic=\(summary.microphoneCount) (\(rate(summary.microphoneCount))), "
            + "gamepad=\(summary.gamepadCount) (\(rate(summary.gamepadCount))), "
            + "other=\(summary.otherCount) (\(rate(summary.otherCount)))"
        )

        let flagParts = summary.flagByteHistogram
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { String(format: "0x%02x=%d", $0.key, $0.value) }
        lines.append("mic input tap 0x31 flag bytes: "
            + (flagParts.isEmpty ? "none" : flagParts.joined(separator: ", ")))

        lines.append("mic input tap mic counter: "
            + Self.describe(summary.microphoneCounter))
        lines.append("mic input tap gamepad sequence: "
            + Self.describe(summary.gamepadSequence))
        lines.append("mic input tap transport nibble (all 0x31): "
            + Self.describe(summary.combinedTransportNibble))
        lines.append("mic input tap transport nibble (mic): "
            + Self.describe(summary.microphoneTransportNibble))
        lines.append("mic input tap transport nibble (gamepad): "
            + Self.describe(summary.gamepadTransportNibble))

        if let interval = summary.microphoneInterArrival {
            let modal = interval.histogramMs
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key)ms×\($0.value)" }
                .joined(separator: ", ")
            lines.append(String(
                format: "mic input tap mic inter-arrival: p50=%.1fms p95=%.1fms "
                    + "min=%.1fms max=%.1fms mean=%.1fms bursts<2ms=%d modal=[%@]",
                interval.p50Ms,
                interval.p95Ms,
                interval.minMs,
                interval.maxMs,
                interval.meanMs,
                interval.burstsUnder2Ms,
                modal
            ))
        } else {
            lines.append("mic input tap mic inter-arrival: insufficient samples")
        }
        return lines
    }

    private static func describe(_ analysis: CounterAnalysis) -> String {
        guard analysis.sampleCount > 1 else {
            return "samples=\(analysis.sampleCount) (insufficient)"
        }
        let deltas = analysis.deltaHistogram
            .sorted { $0.key < $1.key }
            .prefix(6)
            .map { "+\($0.key)×\($0.value)" }
            .joined(separator: ", ")
        let received = analysis.receivedPerSecond
            .map { String(format: "%.1f/s", $0) } ?? "n/a"
        let generated = analysis.estimatedGeneratedPerSecond
            .map { String(format: "%.1f/s", $0) } ?? "n/a"
        return "samples=\(analysis.sampleCount), deltas=[\(deltas)], "
            + "missed=\(analysis.missed), duplicates=\(analysis.duplicates), "
            + "backwards=\(analysis.backwards), received=\(received), "
            + "estimatedGenerated=\(generated)"
    }

    private func counterAnalysis(for reportClass: ReportClass) -> CounterAnalysis {
        analyzeCounters(
            modulus: 256,
            include: { $0 == reportClass.rawValue },
            value: { counters[$0] }
        )
    }

    private func transportNibbleAnalysis(
        include: (UInt8) -> Bool
    ) -> CounterAnalysis {
        analyzeCounters(
            modulus: 16,
            include: include,
            value: { flags[$0] >> 4 }
        )
    }

    private func analyzeCounters(
        modulus: Int,
        include: (UInt8) -> Bool,
        value: (Int) -> UInt8
    ) -> CounterAnalysis {
        var deltaHistogram: [Int: Int] = [:]
        var missed = 0
        var duplicates = 0
        var backwards = 0
        var sampleCount = 0
        var previousCounter: Int?
        var firstNanos: UInt64?
        var lastNanos: UInt64 = 0
        let backwardsThreshold = modulus / 2

        for index in 0..<recordCount where include(classes[index]) {
            sampleCount += 1
            if firstNanos == nil { firstNanos = timestamps[index] }
            lastNanos = timestamps[index]
            let counter = Int(value(index))
            if let previous = previousCounter {
                let delta = (counter - previous + modulus) % modulus
                deltaHistogram[delta, default: 0] += 1
                if delta == 0 {
                    duplicates += 1
                } else if delta > backwardsThreshold {
                    backwards += 1
                } else {
                    missed += delta - 1
                }
            }
            previousCounter = counter
        }

        var receivedPerSecond: Double?
        var generatedPerSecond: Double?
        if let firstNanos, sampleCount >= 2, lastNanos > firstNanos {
            let span = Double(lastNanos - firstNanos) / 1e9
            receivedPerSecond = Double(sampleCount - 1) / span
            generatedPerSecond = Double(sampleCount - 1 + missed) / span
        }

        return CounterAnalysis(
            sampleCount: sampleCount,
            deltaHistogram: deltaHistogram,
            missed: missed,
            duplicates: duplicates,
            backwards: backwards,
            receivedPerSecond: receivedPerSecond,
            estimatedGeneratedPerSecond: generatedPerSecond
        )
    }

    private func intervalAnalysis(for reportClass: ReportClass) -> IntervalAnalysis? {
        var deltasMs: [Double] = []
        var histogram: [Int: Int] = [:]
        var bursts = 0
        var previousNanos: UInt64?

        for index in 0..<recordCount where classes[index] == reportClass.rawValue {
            if let previous = previousNanos {
                let deltaMs = Double(timestamps[index] &- previous) / 1e6
                deltasMs.append(deltaMs)
                histogram[Int(deltaMs.rounded()), default: 0] += 1
                if deltaMs < 2 { bursts += 1 }
            }
            previousNanos = timestamps[index]
        }

        guard deltasMs.count >= 2 else { return nil }
        let sorted = deltasMs.sorted()
        func percentile(_ fraction: Double) -> Double {
            let position = fraction * Double(sorted.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, sorted.count - 1)
            let weight = position - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }

        return IntervalAnalysis(
            minMs: sorted.first ?? 0,
            maxMs: sorted.last ?? 0,
            meanMs: deltasMs.reduce(0, +) / Double(deltasMs.count),
            p50Ms: percentile(0.5),
            p95Ms: percentile(0.95),
            burstsUnder2Ms: bursts,
            histogramMs: histogram
        )
    }
}
