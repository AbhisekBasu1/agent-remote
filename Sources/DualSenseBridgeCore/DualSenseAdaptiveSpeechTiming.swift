/// Estimates how much compacted controller audio must be expanded from Sony's
/// microphone frame counter. Every received Opus frame represents 10 ms, and
/// the modulo-256 counter advances across frames the Bluetooth scheduler did
/// not transmit. This lets each session use its measured loss ratio instead
/// of imposing one historical constant on every recording.
public struct DualSenseAdaptiveSpeechTiming: Sendable {
    /// A short startup prior derived from the paired Bluetooth captures. It is
    /// used only until eight real frames make the current counter informative.
    public static let startupTimeRatio = 2.32
    /// The first reports arrive immediately after the HID route is armed and
    /// are not representative of the steady 15/30 ms Bluetooth interleave.
    /// In the newest paired capture the eight-frame estimate collapsed to
    /// 1.50 before converging to 2.29, audibly warping the opening words.
    /// The latest paired capture showed that holding the prior for 960 ms
    /// smeared the opening phrase after the live delivery ratio had already
    /// stabilized. Forty-eight received frames retains startup protection but
    /// switches early enough to preserve short opening words.
    public static let calibrationFrameCount = 48

    public private(set) var receivedFrameCount = 0
    public private(set) var generatedFrameCount = 0
    public private(set) var timeRatio = startupTimeRatio

    private var previousCounter: UInt8?

    public init() {}

    @discardableResult
    public mutating func observe(counter: UInt8) -> Double {
        receivedFrameCount += 1
        if let previousCounter {
            let delta = (Int(counter) - Int(previousCounter) + 256) % 256
            // Values above half the counter range are reordered/backwards,
            // while zero is a duplicate. Neither should create a huge timing
            // correction; count that received frame as one ordinary interval.
            generatedFrameCount += (1...128).contains(delta) ? delta : 1
        } else {
            generatedFrameCount = 1
        }
        previousCounter = counter

        if receivedFrameCount >= Self.calibrationFrameCount {
            timeRatio = min(
                max(
                    Double(generatedFrameCount) / Double(receivedFrameCount),
                    1.0
                ),
                4.0
            )
        } else {
            timeRatio = Self.startupTimeRatio
        }
        return timeRatio
    }

    public mutating func reset() {
        receivedFrameCount = 0
        generatedFrameCount = 0
        timeRatio = Self.startupTimeRatio
        previousCounter = nil
    }
}
