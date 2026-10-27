import Foundation

public struct Options {
    public var force = false
    // How often to ask the API how far a task got, and how long without progress before going on
    public var pollInterval: TimeInterval = 3
    public var idleTimeout: TimeInterval? = nil
    public init(force: Bool = false) { self.force = force }
}

/**
 * Translates the source language of a String Catalog (.xcstrings) into `targetLangs`, in the same file.
 * A localization that differs from what this tool last wrote is a manual edit (or Xcode's) and is kept until its
 * source changes. `cacheFile` remembers, per language, the version and what was written. A cut run resumes.
 */
public func translate(api: TranslateApi, file: URL, cacheFile: URL, sourceLang: String, targetLangs: [String], options: Options = Options()) async throws {
    var catalog = try JSON.parse(Data(contentsOf: file))
    if let declared = catalog["sourceLanguage"]?.string, declared != sourceLang {
        throw ApiError("Translate Projects: \(file.lastPathComponent) has sourceLanguage \"\(declared)\", not \"\(sourceLang)\"")
    }
    let srcs = sources(catalog, sourceLang: sourceLang)
    // Keyed by the text hash, like the backend does, so an edited text never comes back with a stale translation
    var texts: [String: String] = [:]
    for text in srcs.values.flatMap(units) where !isIgnored(text) { texts[shortHash(text)] = text }
    let version = shortHash("[" + texts.keys.sorted().map(JSON.quote).joined(separator: ",") + "]")
    let routeFile = file.lastPathComponent
    log("Translate Projects: \(srcs.count) strings (\(texts.count) texts) in \(sourceLang)")
    (api as? Api)?.timeout = 60 + Double(texts.count) / 10
    // Queued behind other tasks, a task can stay silent for a while; bigger projects queue longer
    let idle = options.idleTimeout ?? 300 + Double(texts.count) / 5

    let fileHash = shortHash(routeFile)
    let uploaded = { try await api.validateChanges([fileHash: version])[fileHash] == nil }
    let upload = try await !uploaded()
    if upload {
        log("Translate Projects: uploading \(texts.count) texts...")
        guard try await api.loadSources(texts, sourceLang: sourceLang, routeFile: routeFile, version: version) != nil else {
            throw ApiError("Translate Projects: sources upload failed")
        }
        try await wait(idle: 60, every: options.pollInterval) { try await uploaded() ? 1 : 0 }
    } else {
        log("Translate Projects: sources unchanged, upload skipped")
    }

    var cache = (try? JSON.parse(Data(contentsOf: cacheFile)).object) ?? [:]
    let has = { (lang: String) in (catalog["strings"]?.object ?? [:]).values.contains { $0["localizations"]?[lang] != nil } }
    // Fingerprint of the server's translations per language: it changes when someone corrects them there.
    // An older server without the endpoint gives none and only the source version counts.
    let server = (try? await api.versions(routeFile: routeFile)) ?? [:]
    let pending = targetLangs.filter { $0 != sourceLang }.filter { lang in
        let sameSources = !options.force && cache[lang]?["version"]?.string == version && has(lang)
        let sameServer = server[lang] == nil || cache[lang]?["server"]?.string == server[lang]
        if sameSources && sameServer { log("Translate Projects: \(lang) is up to date, skipped") }
        if sameSources && !sameServer { log("Translate Projects: \(lang) has corrections on the server, downloading") }
        return !(sameSources && sameServer)
    }

    // The server translates the languages in parallel; they are written to the catalog one by one as they finish
    try await withThrowingTaskGroup(of: (String, [String: String]).self) { group in
        for lang in pending {
            group.addTask { (lang, try await fetch(api: api, texts: texts, version: version, sourceLang: sourceLang, lang: lang, routeFile: routeFile, upload: upload, idle: idle, every: options.pollInterval)) }
        }
        for try await (lang, byHash) in group {
            cache[lang] = apply(&catalog, srcs: srcs, byHash: byHash, version: version, lang: lang, previous: cache[lang], force: options.force, routeFile: routeFile)
            // Saved per language, so a cut run keeps the languages that finished
            try (catalog.serialized() + "\n").write(to: file, atomically: true, encoding: .utf8)
            try (JSON.object(cache).serialized() + "\n").write(to: cacheFile, atomically: true, encoding: .utf8)
        }
    }
    if !pending.isEmpty, let after = try? await api.versions(routeFile: routeFile) {
        for lang in pending where cache[lang] != nil { cache[lang]?["server"] = after[lang].map(JSON.string) }
        try (JSON.object(cache).serialized() + "\n").write(to: cacheFile, atomically: true, encoding: .utf8)
    }
    log("Translate Projects: done, \(api.requests) HTTP requests")
}

private func fetch(api: TranslateApi, texts: [String: String], version: String, sourceLang: String, lang: String,
                   routeFile: String, upload: Bool, idle: TimeInterval, every: TimeInterval) async throws -> [String: String] {
    let done = { (byHash: [String: String]) in Double(texts.keys.filter { byHash[$0] != nil }.count) / Double(max(texts.count, 1)) }
    // After an upload the translation task must run anyway: with cache_hash it marks every text of the file with
    // this version, otherwise validate-changes keeps reporting the file as changed
    if !upload {
        let byHash = try await api.getTranslations(lang, routeFile: routeFile)
        if done(byHash) == 1 {
            log("Translate Projects: \(lang) already translated on the server, downloading")
            return byHash
        }
    }
    log("Translate Projects: \(lang) translating \(texts.count) texts (the server reuses what it already has)...")
    if let task = try await api.makeTranslations(sourceLang: sourceLang, targetLang: lang, routeFile: routeFile, version: version) {
        // The socket says when the server finished, also with texts it could not translate; polling alone would wait `idle` for them
        let finished = Finished(api.progressURL(task))
        defer { finished.close() }
        var lastStep = -1
        try await wait(idle: idle, every: every) {
            if finished.value { return 1 }
            let progress = done(try await api.getTranslations(lang, routeFile: routeFile))
            let step = Int(progress * 10)
            if step > lastStep {
                lastStep = step
                log("Translate Projects: \(lang) \(Int(progress * 100)) % (\(Int(progress * Double(texts.count)))/\(texts.count) texts)")
            }
            return progress
        }
    }
    return try await api.getTranslations(lang, routeFile: routeFile)
}

/**
 * Polls `progress` (0...1) until it reaches 1; gives up after `idle` seconds without it moving.
 * shortcut: the progress itself comes from polling the translations; fine up to a few thousand texts,
 * read the socket's percentages instead if the payload of each poll grows too big.
 */
func wait(idle: TimeInterval, every: TimeInterval, _ progress: () async throws -> Double) async throws {
    var last = -1.0, since = Date()
    while true {
        let p = (try? await progress()) ?? last
        if p >= 1 { return }
        if p > last { (last, since) = (p, Date()) }
        if Date().timeIntervalSince(since) > idle {
            log("Translate Projects: no progress for \(Int(idle))s, continuing.")
            return
        }
        try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
    }
}

/** Writes one language into the catalog; returns its cache entry. */
func apply(_ catalog: inout JSON, srcs: [String: JSON], byHash: [String: String], version: String, lang: String,
           previous: JSON?, force: Bool, routeFile: String) -> JSON {
    let written = previous?["keys"]?.object ?? [:] // key → [source, output], both serialized
    var strings = catalog["strings"]?.object ?? [:]
    var keys: [String: JSON] = [:]
    var translated = 0, manual = 0, missing = 0
    for (key, src) in srcs.sorted(by: { $0.key < $1.key }) {
        var entry = strings[key] ?? .object([:])
        let current = entry["localizations"]?[lang]
        var before: [String] = []
        if case .array(let pair)? = written[key] { before = pair.compactMap(\.string) }
        let source = src.serialized()
        // Manual = differs from what we last wrote for this same source. A key the cache does not know is new, never
        // manual; only on the first run of a language (no cache) are existing values kept. force overwrites them all.
        let manualEdit = !force && current != nil &&
            (before.count == 2 ? before[0] == source && current!.serialized() != before[1] : previous == nil)
        if manualEdit {
            manual += 1
            keys[key] = .array([.string(source), .string(before.count == 2 ? before[1] : "")])
            continue
        }
        var skipped: [String] = []
        let value = mirror(src, lang: lang) { text in
            if isIgnored(text) { return text }
            guard let t = byHash[shortHash(text)] else { return nil }
            let ok = check(t, source: text)
            if ok == nil { skipped.append(text) }
            return ok
        }
        if let value {
            var localizations = entry["localizations"]?.object ?? [:]
            localizations[lang] = value
            entry["localizations"] = .object(localizations)
            strings[key] = entry
            keys[key] = .array([.string(source), .string(value.serialized())])
            translated += 1
        } else {
            for text in skipped { log("Translate Projects: \(lang): placeholders changed, skipped \"\(text)\"") }
            missing += 1
        }
    }
    catalog["strings"] = .object(strings)
    log("Translate Projects: \(lang) → \(routeFile) (\(translated) translated, \(manual) manual kept, \(missing) missing)")
    if missing > 0 {
        log("Translate Projects: \(lang): \(missing) strings without translation, run again to resume. Check that the project has an AI model and API key configured.")
    }
    return .object(["version": .string(missing > 0 ? "" : version), "keys": .object(keys)])
}
