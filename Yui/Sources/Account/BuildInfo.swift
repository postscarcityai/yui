import Foundation

/// Which Yui is on this phone (YUI-92): version and build, where it came from,
/// the commit and build date, and the channel guide it speaks. Commit, date and
/// guide are stamped into Info.plist at build time by scripts/build_stamp.sh;
/// a plain Xcode build has none of them and says so.
enum BuildInfo {
    private static func stamp(_ key: String) -> String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String, !v.isEmpty, !v.hasPrefix("$(") else { return nil }
        return v
    }

    static let version = stamp("CFBundleShortVersionString") ?? "?"
    static let build = stamp("CFBundleVersion") ?? "?"
    static let commit = stamp("YuiCommit")
    static let guide = stamp("YuiChannelGuide")
    static let built: Date? = stamp("YuiBuildDate").flatMap { try? Date($0, strategy: .iso8601) }

    /// "0.2.0 (96)"
    static var versionLine: String { "\(version) (\(build))" }

    /// Dev link builds carry their own bundle id (YUI-91). TestFlight installs
    /// ship a sandbox receipt; App Store installs a production one.
    static var channel: String {
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true { return "Dev link build" }
        #if DEBUG
        return "Xcode"
        #else
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" { return "TestFlight" }
        return "App Store"
        #endif
    }

    /// The copied block, ready to paste into feedback.
    static var summary: String {
        var lines = ["Yui \(versionLine)", channel]
        if let commit {
            let date = built.map { ", built \($0.formatted(date: .numeric, time: .shortened))" } ?? ""
            lines.append("Commit \(commit)\(date)")
        } else {
            lines.append("Local build")
        }
        if let guide { lines.append("Channel guide \(guide)") }
        return lines.joined(separator: "\n")
    }
}
