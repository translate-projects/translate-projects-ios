import Foundation
import TranslateProjectsKit

setvbuf(stdout, nil, _IOLBF, 0) // progress lines show up as they come, also when piped

let usage = """
Usage: translate-projects-ios [--source es] [--langs en,pt-BR] [--file path/Localizable.xcstrings] [--token-file .translate-projects-token] [--directory .] [--force]
Settings also come from translate-projects.json in the directory: {"sourceLang": "es", "targetLangs": ["en", "pt-BR"], "file": "...", "tokenFile": "..."}
Token: TRANSLATE_PROJECTS_API_KEY or the token file (the token alone or a TRANSLATE_PROJECTS_API_KEY=... line).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var flags: [String: String] = [:]
var force = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--force": force = true
    case "-h", "--help": print(usage); exit(0)
    case "--source", "--langs", "--file", "--token-file", "--directory":
        guard let value = args.next() else { fail("Missing value for \(arg)\n\(usage)") }
        flags[arg] = value
    default: fail("Unknown option \(arg)\n\(usage)")
    }
}

let root = URL(fileURLWithPath: flags["--directory"] ?? FileManager.default.currentDirectoryPath)
let configURL = root.appendingPathComponent("translate-projects.json")
let config = (try? JSON.parse(Data(contentsOf: configURL))) ?? .object([:])
let resolve = { (path: String) in path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path) }

guard let sourceLang = flags["--source"] ?? config["sourceLang"]?.string else { fail("Missing --source (or sourceLang in translate-projects.json)\n\(usage)") }
var targetLangs = flags["--langs"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
if targetLangs.isEmpty, case .array(let langs)? = config["targetLangs"] { targetLangs = langs.compactMap(\.string) }
if targetLangs.isEmpty { fail("Missing --langs (or targetLangs in translate-projects.json)\n\(usage)") }

let file: URL
if let path = flags["--file"] ?? config["file"]?.string {
    file = resolve(path)
} else {
    // Without a path, the only String Catalog in the project (build folders aside)
    let skip: Set<String> = [".build", "build", "DerivedData", "Pods", "Carthage", "node_modules", ".git"]
    var found: [URL] = []
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = walker?.nextObject() as? URL {
        if skip.contains(url.lastPathComponent) { walker?.skipDescendants() } else if url.pathExtension == "xcstrings" { found.append(url) }
    }
    let localizable = found.filter { $0.lastPathComponent == "Localizable.xcstrings" }
    guard let only = localizable.count == 1 ? localizable.first : found.count == 1 ? found.first : nil else {
        fail(found.isEmpty ? "No .xcstrings file found in \(root.path)" : "Several .xcstrings files, choose one with --file:\n" + found.map(\.path).joined(separator: "\n"))
    }
    file = only
}
guard FileManager.default.fileExists(atPath: file.path) else { fail("Translate Projects: \(file.path) not found") }

var token = ProcessInfo.processInfo.environment["TRANSLATE_PROJECTS_API_KEY"]
if let tokenFile = flags["--token-file"] ?? config["tokenFile"]?.string {
    guard let raw = try? String(contentsOf: resolve(tokenFile), encoding: .utf8) else { fail("Translate Projects: cannot read \(tokenFile)") }
    token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"^(export\s+)?TRANSLATE_PROJECTS_API_KEY=["']?|["']$"#, with: "", options: .regularExpression)
}

let cacheFile = file.deletingPathExtension().appendingPathExtension("translate-projects.json")
do {
    try await translate(api: Api(token: token), file: file, cacheFile: cacheFile, sourceLang: sourceLang, targetLangs: targetLangs, options: Options(force: force))
} catch {
    fail("\(error)")
}
