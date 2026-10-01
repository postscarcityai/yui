import XCTest

/// Agent tables on the phone (YUI-89, spec TABLES.md). The starters from the playground (samples.mjs) are
/// loaded as an agent reply, so their `table create` and `put` lines write the phone's store and their
/// `query` lines draw it. Demo account, no network. Screenshots go to `YUI_SHOTS` when set; the events a
/// tap sent are read back from the event log.
final class AgentTablesTests: XCTestCase {
    static let workout = """
    table create lifts Day:date Lift:text Weight:number:lb Reps:number
    put lifts Day=today-6 Lift=Squat Weight=215 Reps=5
    put lifts Day=today-6 Lift=Bench Weight=175 Reps=5
    put lifts Day=today-4 Lift=Squat Weight=225 Reps=5
    put lifts Day=today-4 Lift=Bench Weight=180 Reps=5
    put lifts Day=today-2 Lift=Squat Weight=230 Reps=5
    put lifts Day=today-2 Lift=Deadlift Weight=275 Reps=3
    put lifts Day=today Lift=Squat Weight=235 Reps=5
    query lifts where=Lift=Squat sort=Day as chart x=Day y=Weight "Squat, top set"
    query lifts group=Lift max=Weight sum=Reps +count sort=-Weight as table "Best set per lift"
    """

    static let macros = """
    table create meals Day:date Food:text Cal:number:kcal Protein:number:g
    put meals Day=today-2 Food="Chicken bowl" Cal=640 Protein=52
    put meals Day=today-2 Food=Oats Cal=300 Protein=10
    put meals Day=today-1 Food="Salmon and rice" Cal=720 Protein=45
    put meals Day=today-1 Food="Greek yogurt" Cal=150 Protein=20
    put meals Day=today Food="Eggs and toast" Cal=420 Protein=26
    put meals Day=today Food="Turkey wrap" Cal=510 Protein=38
    query meals group=Day sum=Cal sort=Day as stat y=Cal label="Calories today" good=down
    query meals where=Day=today cols=Food|Cal|Protein as table "Today so far"
    query meals group=Day sum=Protein sort=Day as chart bar x=Day y=Protein "Protein by day"
    """

    static let crm = """
    table create crm Name:text Stage:text Value:number:$ Next:date Won:bool
    put crm acme Name="Acme Co" Stage=Proposal Value=12000 Next=today+2
    put crm bolt Name="Bolt Studio" Stage=Lead Value=3000 Next=today+5
    put crm cedar Name="Cedar Dental" Stage=Call Value=8000 Next=today+1
    put crm dune Name="Dune Coffee" Stage=Won Value=4500 +Won
    query crm where=Stage!=Won sort=Next cols=Name|Stage|Value|Next as table "Open deals"
    query crm group=Stage sum=Value as chart bar x=Stage y=Value "Pipeline"
    query crm sort=Next cols=Name|Stage|Won as list check=Won "Mark a deal won"
    """

    static let workouts = """
    table create variations Move:text Swap:text Cue:text
    put variations goblet-squat Move="Goblet squat" Swap="Front squat" Cue="Elbows up, chest tall"
    put variations split-squat Move="Split squat" Swap="Reverse lunge" Cue="Front shin tall, drop straight down"
    put variations push-up Move="Push-up" Swap="Incline push-up" Cue="One line from head to heel"
    put variations row Move="Dumbbell row" Swap="Cable row" Cue="Pull to the hip, not the chest"
    put variations hinge Move="Romanian deadlift" Swap="Hip thrust" Cue="Hips back, soft knees"
    table create workouts Day:date Name:text Focus:text Done:bool
    put workouts w1 Day=today-4 Name="Legs A" Focus=Legs +Done
    put workouts w2 Day=today-2 Name="Push" Focus=Chest +Done
    put workouts w3 Day=today Name="Legs B" Focus=Legs
    put workouts w4 Day=today+2 Name="Pull" Focus=Back
    table create session Slot:number Move:text Sets:number Reps:number Done:bool
    put session 1 Slot=1 Move="Goblet squat" Sets=3 Reps=8
    put session 2 Slot=2 Move="Split squat" Sets=3 Reps=10
    put session 3 Slot=3 Move="Romanian deadlift" Sets=3 Reps=8
    put session 4 Slot=4 Move="Push-up" Sets=2 Reps=12
    query workouts sort=Day cols=Day|Name|Focus|Done as table "This week"
    query session sort=Slot cols=Move|Sets|Reps|Done as list check=Done "Today: Legs B"
    query variations cols=Move|Swap|Cue as table "Swaps I know"
    """

    private var tmp: URL { FileManager.default.temporaryDirectory }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = ProcessInfo.processInfo.environment["YUI_SHOTS"] { try? png.write(to: URL(fileURLWithPath: dir).appending(path: "tables-\(name).png")) }
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = "tables-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func rows(_ yl: String, id: String = "r1") throws -> URL {
        let f = tmp.appending(path: "yui89-\(UUID().uuidString).json")
        let rows: [[String: Any]] = [["id": id, "sender": "agent", "kind": "text", "body": "```yui\n\(yl)\n```", "created_at": "2026-10-01T10:00:00+00:00"]]
        try JSONSerialization.data(withJSONObject: rows).write(to: f)
        return f
    }

    private func launch(_ rowsFile: URL, tables: URL, appearance: String = "light", log: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-yuiDemoAccount", "-yuiDemoAgents", "-yuiAgent", "wizard", "-appearance", appearance,
                               "-yuiThreadRows", rowsFile.path, "-yuiTablesDir", tables.path]
            + (log.map { ["-yuiEventLog", $0] } ?? []) + extra
        app.launch()
        return app
    }

    private func button(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// The three starters and the coach's workouts, light and dark: every query draws from the phone's store.
    func testStartersDrawFromTheStore() throws {
        let cases: [(String, String, String)] = [
            ("workout", Self.workout, "Best set per lift"),
            ("macros", Self.macros, "Today so far"),
            ("crm", Self.crm, "Open deals"),
            ("workouts", Self.workouts, "This week"),
        ]
        for (name, yl, anchor) in cases {
            for look in ["light", "dark"] {
                let dir = tmp.appending(path: "yui89-\(UUID().uuidString)")
                let app = launch(try rows(yl), tables: dir, appearance: look)
                XCTAssertTrue(app.staticTexts[anchor].firstMatch.waitForExistence(timeout: 20), "\(name): \(anchor) never drew")
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No table called")).firstMatch.exists, "\(name): a query found no table")
                sleep(2)
                shot("\(name)-\(look)")
                app.terminate()
            }
        }
    }

    /// Arnold's workouts: tick a move (the row is written and the agent hears it), the agent swaps a move with one
    /// put (the list redraws), kill and relaunch (the rows, the tick and the swap are still there).
    func testWorkoutsTickSwapAndRelaunch() throws {
        let dir = tmp.appending(path: "yui89-\(UUID().uuidString)")
        let log = tmp.appending(path: "yui89-events-\(UUID().uuidString).jsonl").path
        let f = try rows(Self.workouts)
        let app = launch(f, tables: dir, log: log, extra: ["-yuiDemoReply", "put session 1 Move=\"Front squat\""])

        let squat = button(app, "Goblet squat")
        let drew = squat.waitForExistence(timeout: 20)
        shot("workouts-initial")
        XCTAssertTrue(drew, "the session never drew")
        XCTAssertFalse(squat.isSelected)
        squat.tap()
        sleep(1)
        XCTAssertTrue(button(app, "Goblet squat").isSelected, "the tick did not stick")
        let events = (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let tick = events.first { $0.contains("\"op\":\"row\"") }
        XCTAssertNotNil(tick, "the tick sent nothing: \(events)")
        XCTAssertTrue(tick?.contains("\"table\":\"session\"") == true && tick?.contains("\"key\":\"1\"") == true
                      && tick?.contains("\"Done\":true") == true && tick?.contains("\"preset\":\"query\"") == true, tick ?? "")
        shot("workouts-ticked")

        // The agent's turn: one put swaps the move, the sets and the tick stay.
        let field = app.descendants(matching: .any)["composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("swap my first move")
        app.buttons["Send"].tap()
        XCTAssertTrue(button(app, "Front squat").waitForExistence(timeout: 15), "the put did not redraw the list")
        XCTAssertFalse(button(app, "Goblet squat").exists)
        XCTAssertTrue(button(app, "Front squat").isSelected, "the swap lost the tick")
        sleep(1)
        shot("workouts-swapped")
        app.terminate()

        // Kill and relaunch: the same thread loads again and writes nothing twice; the phone's file has it all.
        let again = launch(f, tables: dir)
        let front = button(again, "Front squat")
        XCTAssertTrue(front.waitForExistence(timeout: 20), "the rows did not survive a relaunch")
        XCTAssertTrue(front.isSelected, "the tick did not survive a relaunch")
        XCTAssertFalse(button(again, "Goblet squat").exists)
        sleep(1)
        shot("workouts-relaunched")
    }
}
