// Creates sealed push fixtures (`.apns` files for `xcrun simctl push`) from the TEST-ONLY keys in
// OrchKit/Tests/OrchPushFixtures/PushFixtures.swift. Build and run through scripts/make-push-fixture.sh:
//   scripts/make-push-fixture.sh [--out DIR] [--now-ms N]
// Writes: NN_<case>.apns (question, closure, replay, stale, unknown workspace, forged WSK, tampered, malicious outer
// fields), material.arg (the `--push-material` launch argument for the app's DEBUG push harness) and expectations.json
// (what the notification extension must record and show per case). Send them in file order: later cases depend on the
// replay state earlier ones leave. The keys are public and protect nothing.
import Foundation

@main
enum MakePushFixture {
    static func main() throws {
        var out = FileManager.default.currentDirectoryPath + "/push-fixtures"
        var now = Int64(Date().timeIntervalSince1970 * 1000)
        var args = CommandLine.arguments.dropFirst()
        while let a = args.popFirst() {
            switch a {
            case "--out": out = args.popFirst() ?? out
            case "--now-ms": now = Int64(args.popFirst() ?? "") ?? now
            default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
            }
        }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var expectations: [[String: Any]] = []
        for f in PushFixtures.sequence(nowMs: now) {
            try f.apns.write(to: dir.appendingPathComponent("\(f.name).apns"))
            expectations.append(["name": f.name, "outcome": f.expectedOutcome, "body": f.expectedBody ?? "generic", "maxTs": String(f.expectedMaxTs)])
        }
        let w = PushFixtures.workspaceA
        try Data("\(w.id.hex):\(B64U.encode(PushFixtures.materialJSON(w)))".utf8).write(to: dir.appendingPathComponent("material.arg"))
        try JSONSerialization.data(withJSONObject: expectations, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("expectations.json"))
        print("wrote \(expectations.count) fixtures to \(dir.path) (now_ms=\(now))")
    }
}
