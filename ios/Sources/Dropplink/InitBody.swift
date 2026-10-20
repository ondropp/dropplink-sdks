import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The `/v1/init` body (spec §4). iOS never sends `installReferrer`.
struct InitBody: Encodable, Equatable {
    let installId: String
    let platform: String
    let appVersion: String
    let sdkVersion: String
    let device: DeviceInfo

    init(installId: String, appVersion: String, sdkVersion: String, device: DeviceInfo) {
        self.installId = installId
        self.platform = "ios"
        self.appVersion = String(appVersion.truncated(to: 64))
        self.sdkVersion = String(sdkVersion.truncated(to: 32))
        self.device = device
    }
}

struct DeviceInfo: Encodable, Equatable, Sendable {
    struct Screen: Encodable, Equatable, Sendable {
        let w: Int
        let h: Int
        let dpr: Double
    }

    let model: String
    let osVersion: String
    let locale: String
    let timezone: String
    /// Optional in the contract; `nil` where there's no UIScreen (macOS tests, extensions without one).
    let screen: Screen?

    /// Truncates to the contract's max lengths so the server never rejects a long value.
    init(model: String, osVersion: String, locale: String, timezone: String, screen: Screen?) {
        self.model = model.truncated(to: 100)
        self.osVersion = osVersion.truncated(to: 32)
        self.locale = locale.truncated(to: 35)
        self.timezone = timezone.truncated(to: 64)
        self.screen = screen
    }

    /// Reads this device's details. Async because the screen is main-actor state.
    static func current() async -> DeviceInfo {
        DeviceInfo(
            model: hardwareModel(),
            osVersion: osVersion(),
            locale: bcp47(Locale.current),
            timezone: TimeZone.current.identifier,
            screen: await screen()
        )
    }

    /// `utsname.machine`, e.g. `iPhone16,1`. In the simulator that's the Mac's `arm64`, so use the
    /// simulated model instead.
    static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// Same format as `UIDevice.current.systemVersion` ("18.1", "17.4.1"), but readable off the
    /// main actor, where UIDevice isn't.
    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// `en_IN@calendar=gregorian` → `en-IN`.
    static func bcp47(_ locale: Locale) -> String {
        let identifier = locale.identifier.split(separator: "@").first.map(String.init) ?? locale.identifier
        return identifier.replacingOccurrences(of: "_", with: "-")
    }

    static func screen() async -> Screen? {
        #if canImport(UIKit) && !os(watchOS)
        return await MainActor.run {
            // Pixels = points × scale, as the spec says. `UIScreen.main` still works on every iOS
            // version this SDK supports and needs no scene, which the SDK can't assume it has.
            let screen = UIScreen.main
            let scale = screen.scale
            let size = screen.bounds.size
            guard scale > 0, size.width > 0, size.height > 0 else { return nil }
            return Screen(w: Int((size.width * scale).rounded()), h: Int((size.height * scale).rounded()), dpr: Double(scale))
        }
        #else
        return nil
        #endif
    }
}

/// The `/v1/init` app version: `CFBundleShortVersionString`, or `"unknown"`.
func currentAppVersion(bundle: Bundle = .main) -> String {
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return (version?.isEmpty == false ? version : nil) ?? "unknown"
}

extension String {
    /// Keeps at most `max` UTF-16 code units (how the server's validator measures length) without
    /// splitting a character.
    func truncated(to max: Int) -> String {
        guard utf16.count > max else { return self }
        var result = ""
        for character in self {
            if result.utf16.count + character.utf16.count > max { break }
            result.append(character)
        }
        return result
    }
}
