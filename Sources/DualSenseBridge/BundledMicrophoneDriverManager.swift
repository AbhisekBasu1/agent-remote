import Foundation

enum BundledMicrophoneDriverState: Equatable {
    case missing
    case updateAvailable
    case installed
}

enum BundledMicrophoneDriverError: LocalizedError {
    case bundledFilesMissing
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledFilesMissing:
            return "The app does not contain its DualSense Bridge Mic driver tools."
        case let .authorizationFailed(message):
            return message
        }
    }
}

final class BundledMicrophoneDriverManager {
    static let bundleIdentifier =
        "io.github.abhisekbasu1.AgentRemote.MicrophoneDriver"
    static let legacyBundleIdentifier = "local.controllerproject.DualSenseBridgeMic"
    static let driverName = "DualSenseBridgeMic.driver"

    private let installedDriverURL = URL(
        fileURLWithPath: "/Library/Audio/Plug-Ins/HAL",
        isDirectory: true
    ).appendingPathComponent(driverName, isDirectory: true)

    var state: BundledMicrophoneDriverState {
        guard let installedBundle = Bundle(url: installedDriverURL),
              let installedIdentifier = installedBundle.bundleIdentifier,
              installedIdentifier == Self.bundleIdentifier
                || installedIdentifier == Self.legacyBundleIdentifier else {
            return .missing
        }
        guard installedIdentifier == Self.bundleIdentifier else {
            return .updateAvailable
        }
        guard let bundledBundle = bundledDriverURL.flatMap(Bundle.init(url:)),
              let bundledVersion = bundledBundle.object(
                forInfoDictionaryKey: kCFBundleVersionKey as String
              ) as? String,
              let installedVersion = installedBundle.object(
                forInfoDictionaryKey: kCFBundleVersionKey as String
              ) as? String else {
            return .installed
        }
        return installedVersion == bundledVersion ? .installed : .updateAvailable
    }

    func install() throws {
        guard let driverURL = bundledDriverURL,
              let installerURL = Bundle.main.url(
                forResource: "install-driver",
                withExtension: "sh"
              ) else {
            throw BundledMicrophoneDriverError.bundledFilesMissing
        }

        let script = """
        set installerPath to "\(appleScriptLiteral(installerURL.path))"
        set driverPath to "\(appleScriptLiteral(driverURL.path))"
        set commandText to quoted form of installerPath & " " & quoted form of driverPath
        do shell script commandText with administrator privileges
        """
        var error: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
            let message = error?[NSAppleScript.errorMessage] as? String
                ?? "macOS did not install the audio driver."
            throw BundledMicrophoneDriverError.authorizationFailed(message)
        }
    }

    func uninstall() throws {
        guard let uninstallerURL = Bundle.main.url(
            forResource: "uninstall-driver",
            withExtension: "sh"
        ) else {
            throw BundledMicrophoneDriverError.bundledFilesMissing
        }

        let script = """
        set uninstallerPath to "\(appleScriptLiteral(uninstallerURL.path))"
        set commandText to quoted form of uninstallerPath
        do shell script commandText with administrator privileges
        """
        var error: NSDictionary?
        guard NSAppleScript(source: script)?.executeAndReturnError(&error) != nil else {
            let message = error?[NSAppleScript.errorMessage] as? String
                ?? "macOS did not uninstall the audio driver."
            throw BundledMicrophoneDriverError.authorizationFailed(message)
        }
    }

    private var bundledDriverURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent(
            Self.driverName,
            isDirectory: true
        )
    }

    private func appleScriptLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
