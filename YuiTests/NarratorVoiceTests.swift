import XCTest
@testable import Yui

/// TestFlight: "this voice sounds like a retarded Stephen Hawking". A phone
/// with no enhanced voices has 28 default-quality en-US voices, and only
/// Samantha among them sounds human. Hashing the agent name across all of
/// them landed on a robot almost every time.
@MainActor
final class NarratorVoiceTests: XCTestCase {
    typealias V = Narrator.VoiceInfo

    /// The en-US voices a stock iPhone ships with (quality 1 = default).
    static let stock: [V] =
        ["Eddy", "Flo", "Grandma", "Grandpa", "Reed", "Rocko", "Sandy", "Shelley"].map {
            V(id: "com.apple.eloquence.en-US.\($0)", language: "en-US", quality: 1)
        } + ["Fred", "Junior", "Kathy", "Ralph"].map {
            V(id: "com.apple.speech.synthesis.voice.\($0)", language: "en-US", quality: 1)
        } + ["Albert", "BadNews", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Deranged",
             "GoodNews", "Hysterical", "Organ", "Princess", "Trinoids", "Whisper", "Zarvox"].map {
            V(id: "com.apple.speech.synthesis.voice.\($0)", language: "en-US", quality: 1, novelty: true)
        } + [V(id: "com.apple.voice.compact.en-US.Samantha", language: "en-US", quality: 1)]

    static let agents = ["Yui", "Urza", "Arnold", "coach", "zen", "a", ""]

    func testStockPhoneNeverGetsARobot() {
        for agent in Self.agents {
            XCTAssertEqual(Narrator.pick(Self.stock, language: "en-US", agent: agent),
                           "com.apple.voice.compact.en-US.Samantha", "agent \(agent) got a robot voice")
        }
    }

    func testPremiumBeatsEnhancedBeatsCompact() {
        let enhanced = V(id: "com.apple.voice.enhanced.en-US.Evan", language: "en-US", quality: 2)
        let premium = V(id: "com.apple.voice.premium.en-US.Ava", language: "en-US", quality: 3)
        XCTAssertEqual(Narrator.pick(Self.stock + [enhanced], language: "en-US", agent: "Yui"), enhanced.id)
        XCTAssertEqual(Narrator.pick(Self.stock + [enhanced, premium], language: "en-US", agent: "Yui"), premium.id)
    }

    func testAgentsSplitSeveralGoodVoices() {
        let premiums = ["Ava", "Zoe", "Nathan"].map { V(id: "com.apple.voice.premium.en-US.\($0)", language: "en-US", quality: 3) }
        let picks = Set(Self.agents.compactMap { Narrator.pick(Self.stock + premiums, language: "en-US", agent: $0) })
        XCTAssertGreaterThan(picks.count, 1, "every agent got the same voice")
        XCTAssertTrue(picks.isSubset(of: Set(premiums.map(\.id))))
        XCTAssertEqual(Narrator.pick(Self.stock + premiums, language: "en-US", agent: "Yui"),
                       Narrator.pick(Self.stock + premiums, language: "en-US", agent: "Yui"), "an agent's voice is not stable")
    }

    func testNeverAPersonalVoiceOrRobotOnly() {
        let personal = V(id: "com.apple.speech.personalvoice.Chris", language: "en-US", quality: 3, personal: true)
        XCTAssertNotEqual(Narrator.pick(Self.stock + [personal], language: "en-US", agent: "Yui"), personal.id)
        let robots = Self.stock.filter { !$0.id.contains("Samantha") }
        XCTAssertNil(Narrator.pick(robots, language: "en-US", agent: "Yui"), "fell back to a robot instead of the system default")
    }

    /// This machine's real voices, when the simulator has any for the language.
    func testInstalledVoicesPickNoRobot() throws {
        let v = try XCTUnwrap(Narrator.voice(nil, lang: "en-US", agent: "Yui"))
        XCTAssertFalse(v.identifier.contains(".eloquence.") || v.identifier.contains(".speech.synthesis.voice."),
                       "picked \(v.identifier)")
    }
}
