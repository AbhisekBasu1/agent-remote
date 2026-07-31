import Darwin
import Foundation

enum BluetoothOpusDecoderError: LocalizedError {
    case libraryUnavailable
    case symbolUnavailable(String)
    case creationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable:
            return "The bundled Opus decoder could not be loaded."
        case let .symbolUnavailable(symbol):
            return "The Opus decoder is missing \(symbol)."
        case let .creationFailed(code):
            return "The Opus decoder could not start (error \(code))."
        }
    }
}

/// Small dynamic wrapper around libopus. Loading it dynamically keeps the
/// package source independent of Homebrew headers; release packaging embeds the
/// redistributable library in the app bundle.
final class BluetoothOpusDecoder: @unchecked Sendable {
    private static let sampleRate: Int32 = 48_000
    private static let channelCount: Int32 = 2
    private static let maximumFrameSamplesPerChannel = 480

    private typealias CreateFunction = @convention(c) (
        Int32,
        Int32,
        UnsafeMutablePointer<Int32>?
    ) -> OpaquePointer?
    private typealias DecodeFunction = @convention(c) (
        OpaquePointer?,
        UnsafePointer<UInt8>?,
        Int32,
        UnsafeMutablePointer<Int16>?,
        Int32,
        Int32
    ) -> Int32
    private typealias DestroyFunction = @convention(c) (OpaquePointer?) -> Void

    private let library: UnsafeMutableRawPointer
    private let decoder: OpaquePointer
    private let decodeFunction: DecodeFunction
    private let destroyFunction: DestroyFunction

    init() throws {
        let candidateURLs: [URL?] = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libopus.0.dylib"),
            URL(fileURLWithPath: "/opt/homebrew/opt/opus/lib/libopus.0.dylib"),
            URL(fileURLWithPath: "/usr/local/opt/opus/lib/libopus.0.dylib")
        ]
        guard let handle = candidateURLs.compactMap({ $0 }).lazy.compactMap({ url in
            dlopen(url.path, RTLD_NOW | RTLD_LOCAL)
        }).first else {
            throw BluetoothOpusDecoderError.libraryUnavailable
        }
        library = handle

        do {
            let create: CreateFunction = try Self.function(
                named: "opus_decoder_create",
                from: handle
            )
            decodeFunction = try Self.function(named: "opus_decode", from: handle)
            destroyFunction = try Self.function(named: "opus_decoder_destroy", from: handle)

            var error: Int32 = 0
            // Sony's Bluetooth CHAT/ASR microphone profile emits coupled
            // stereo Opus: channel 0 is the CHAT voice stream and channel 1
            // is the separately processed ASR stream. Asking libopus for one
            // channel averages those two DSP outputs, which creates comb-like
            // coloration and makes speech sound hollow/robotic. Decode both
            // and select CHAT explicitly below. Re-validated on the Natural
            // (0x01/0x08) source across all fourteen archived takes on
            // 2026-07-22: channel 0 outperformed both channel 1 and a 50/50
            // mix through the identical live pipeline.
            guard let decoder = create(
                Self.sampleRate,
                Self.channelCount,
                &error
            ), error == 0 else {
                throw BluetoothOpusDecoderError.creationFailed(error)
            }
            self.decoder = decoder
            DiagnosticLog.write(
                "Bluetooth Opus decoder: stereo CHAT/ASR input, emitting CHAT channel 0"
            )
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        destroyFunction(decoder)
        dlclose(library)
    }

    func decode(_ packet: Data) -> [Int16]? {
        packet.withUnsafeBytes { packetBuffer in
            decode(
                packet: packetBuffer.bindMemory(to: UInt8.self).baseAddress,
                packetByteCount: Int32(packetBuffer.count)
            )
        }
    }

    /// Advances the Opus decoder across one missing 10 ms microphone packet.
    /// Opus synthesizes a short continuation from its decoder state instead of
    /// leaving a time hole or joining two unrelated waveform edges together.
    func decodePacketLoss() -> [Int16]? {
        decode(packet: nil, packetByteCount: 0, decodeFEC: false)
    }

    /// Advances the predictive decoder state across missing packets without
    /// exposing any synthesized samples. For the loss immediately before the
    /// received packet, ask Opus to use in-band FEC when present; otherwise
    /// libopus performs concealment internally. Earlier consecutive losses
    /// use ordinary PLC in chronological order.
    func advanceAcrossPacketLosses(_ count: Int, before packet: Data) {
        guard count > 0 else { return }
        if count > 1 {
            for _ in 0..<(count - 1) {
                _ = decodePacketLoss()
            }
        }
        _ = packet.withUnsafeBytes { packetBuffer in
            decode(
                packet: packetBuffer.bindMemory(to: UInt8.self).baseAddress,
                packetByteCount: Int32(packetBuffer.count),
                decodeFEC: true
            )
        }
    }

    private func decode(
        packet: UnsafePointer<UInt8>?,
        packetByteCount: Int32,
        decodeFEC: Bool = false
    ) -> [Int16]? {
        var interleavedSamples = [Int16](
            repeating: 0,
            count: Self.maximumFrameSamplesPerChannel * Int(Self.channelCount)
        )
        let decodedCount = interleavedSamples.withUnsafeMutableBufferPointer {
            sampleBuffer in
            decodeFunction(
                decoder,
                packet,
                packetByteCount,
                sampleBuffer.baseAddress,
                Int32(Self.maximumFrameSamplesPerChannel),
                decodeFEC ? 1 : 0
            )
        }
        guard decodedCount > 0 else { return nil }

        let sampleCount = Int(decodedCount)
        var chatSamples = [Int16]()
        chatSamples.reserveCapacity(sampleCount)
        for frame in 0..<sampleCount {
            chatSamples.append(interleavedSamples[frame * Int(Self.channelCount)])
        }
        return chatSamples
    }

    private static func function<T>(
        named name: String,
        from library: UnsafeMutableRawPointer
    ) throws -> T {
        guard let symbol = dlsym(library, name) else {
            throw BluetoothOpusDecoderError.symbolUnavailable(name)
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}
