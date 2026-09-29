import Foundation

/// The wait between "its computer paired" and "its gateway reads its thread"
/// (YUI-192). One rule for the Add agent sheet: listening the moment presence
/// says anything but not_listening, an honest "still nothing" after a minute
/// with a way to try again, never an endless spinner.
enum GatewayWait {
    enum Phase: Equatable {
        case waiting, listening, gaveUp
    }

    /// How long the sheet promises before it says so plainly.
    static let giveUpAfter: TimeInterval =
        ProcessInfo.processInfo.arguments.contains("-yuiGatewayGiveUp") ? 3 : 60
    /// How often the sheet asks the relay while it waits.
    static let pollEvery: Duration = .seconds(2)

    static func phase(_ liveness: YuiAgent.Liveness, waited: TimeInterval) -> Phase {
        if liveness != .notListening { return .listening }
        return waited >= giveUpAfter ? .gaveUp : .waiting
    }
}
