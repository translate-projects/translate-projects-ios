import Foundation
import XCTest
@testable import TranslateProjectsKit

final class FakeApi: TranslateApi {
    var requests = 0, uploads = 0, tasks = 0
    var changed = true
    let dict: [String: String]
    init(_ dict: [String: String]) { self.dict = dict }
    func validateChanges(_ fileHashes: [String: String]) async throws -> [String: JSON] {
        changed && uploads == 0 ? fileHashes.mapValues(JSON.string) : [:]
    }
    func loadSources(_ texts: [String: String], sourceLang: String, routeFile: String, version: String) async throws -> String? {
        uploads += 1
        return "t1"
    }
    func makeTranslations(sourceLang: String, targetLang: String, routeFile: String, version: String) async throws -> String? {
        tasks += 1
        return "t2"
    }
    func getTranslations(_ targetLang: String, routeFile: String) async throws -> [String: String] {
        guard routeFile == "Localizable.xcstrings" else { return [:] }
        return Dictionary(uniqueKeysWithValues: dict.map { (shortHash($0.key), $0.value) })
    }
    func progressURL(_ taskId: String) -> URL? { nil }
}

let en = ["Hola %@": "Hello %@", "Configuración": "Settings", "%lld viajes": "%lld trips", "%lld viaje": "%lld trip", "Cerrar": "Close"]

func unit(_ v: String) -> JSON { .object(["stringUnit": .object(["state": .string("translated"), "value": .string(v)])]) }

final class TranslatorTests: XCTestCase {
    var file: URL!, cache: URL!

    override func setUp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("Localizable.xcstrings")
        cache = dir.appendingPathComponent("Localizable.translate-projects.json")
        try! """
        {"sourceLanguage": "es", "version": "1.0", "strings": {
          "Hola %@": {"comment": "Saludo en el inicio"},
          "settings_title": {"localizations": {"es": {"stringUnit": {"state": "translated", "value": "Configuración"}}}},
          "trips": {"localizations": {"es": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "%lld viaje"}},
            "other": {"stringUnit": {"state": "translated", "value": "%lld viajes"}}}}}}},
          "Ruteo": {"shouldTranslate": false},
          "Cerrar": {},
          "$9.300": {},
          "": {},
          "%@": {}
        }}
        """.write(to: file, atomically: true, encoding: .utf8)
    }

    func catalog() throws -> JSON { try JSON.parse(Data(contentsOf: file)) }
    func run(_ api: FakeApi, _ langs: [String], force: Bool = false) async throws {
        var options = Options(force: force)
        options.pollInterval = 0
        try await translate(api: api, file: file, cacheFile: cache, sourceLang: "es", targetLangs: langs, options: options)
    }

    func testHashMatchesBackend() {
        // Same value as the Node and Kotlin clients
        XCTAssertEqual(shortHash("Localizable.xcstrings"), "1nmad23kumsygtq")
        XCTAssertEqual(shortHash("Iniciar sesión"), "3issc1t9669qjru")
        XCTAssertEqual(SHA256.digest(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTranslatesPlainKeyedAndPluralKeepingComments() async throws {
        let api = FakeApi(en)
        try await run(api, ["en", "pt-BR"])
        let c = try catalog()
        XCTAssertEqual(api.uploads, 1)
        XCTAssertEqual(c["strings"]?["Hola %@"]?["localizations"]?["en"], unit("Hello %@"))
        XCTAssertEqual(c["strings"]?["Hola %@"]?["comment"], .string("Saludo en el inicio"))
        XCTAssertEqual(c["strings"]?["settings_title"]?["localizations"]?["en"], unit("Settings"))
        XCTAssertEqual(c["strings"]?["trips"]?["localizations"]?["en"]?["variations"]?["plural"],
                       .object(["one": unit("%lld trip"), "other": unit("%lld trips")]))
        XCTAssertEqual(c["strings"]?["trips"]?["localizations"]?["pt-BR"]?["variations"]?["plural"]?.object?.keys.sorted(), ["many", "one", "other"])
        XCTAssertNil(c["strings"]?["Ruteo"]?["localizations"])
        for key in ["$9.300", "", "%@"] { XCTAssertEqual(c["strings"]?[key], .object([:]), key) } // nothing to translate
        XCTAssertEqual(c["strings"]?["Ruteo"]?["shouldTranslate"], .bool(false))
        XCTAssertEqual(try JSON.parse(Data(contentsOf: cache))["en"]?["version"]?.string?.count, 15)
    }

    func testNothingChangedSkipsManualEditsSurviveForceOverwrites() async throws {
        try await run(FakeApi(en), ["en"])
        var c = try catalog()
        c["strings"]?["Cerrar"]?["localizations"]?["en"] = unit("Dismiss")
        try c.serialized().write(to: file, atomically: true, encoding: .utf8)

        let again = FakeApi(en)
        again.changed = false
        try await run(again, ["en"])
        XCTAssertEqual(again.tasks, 0)

        var k = try JSON.parse(Data(contentsOf: cache))
        k["en"]?["version"] = .string("") // as if the sources had changed
        try k.serialized().write(to: cache, atomically: true, encoding: .utf8)
        let changed = FakeApi(en.merging(["Hola %@": "Hi %@"]) { $1 })
        changed.changed = false
        try await run(changed, ["en"])
        XCTAssertEqual(try catalog()["strings"]?["Cerrar"]?["localizations"]?["en"], unit("Dismiss"))
        XCTAssertEqual(try catalog()["strings"]?["Hola %@"]?["localizations"]?["en"], unit("Hi %@"))

        try await run(changed, ["en"], force: true)
        XCTAssertEqual(try catalog()["strings"]?["Cerrar"]?["localizations"]?["en"], unit("Close"))
    }

    func testLostPlaceholderIsNotWritten() async throws {
        try await run(FakeApi(en.merging(["Hola %@": "Hello"]) { $1 }), ["en"])
        XCTAssertNil(try catalog()["strings"]?["Hola %@"]?["localizations"])
        XCTAssertEqual(try JSON.parse(Data(contentsOf: cache))["en"]?["version"], .string(""))
    }

    func testPlaceholdersAndSerialization() {
        XCTAssertEqual(check("Tienes %1$@ y %2$lld", source: "You have %1$@ and %2$lld"), "Tienes %1$@ y %2$lld")
        XCTAssertNil(check("%lld", source: "%d"))
        XCTAssertEqual(check("50 % de descuento", source: "50 % off"), "50 % de descuento")
        XCTAssertEqual(check("Hola\nmundo", source: "Hello world"), "Hola mundo")
        XCTAssertEqual(JSON.object(["b": .object([:]), "a": .string("x\n"), "n": .number(2)]).serialized(),
                       "{\n  \"a\" : \"x\\n\",\n  \"b\" : {\n\n  },\n  \"n\" : 2\n}")
    }
}
