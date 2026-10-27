import Foundation

// Texts the backend never stores (helpers/ignore_list.py), so they never come back translated
let ignored: Set<String> = ["", ".", ",", ":", ";", "..."]

/** Nothing to translate: punctuation, prices ("$9.300"), bare placeholders ("%@") or empty. */
func isIgnored(_ text: String) -> Bool {
    ignored.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) ||
        placeholder.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "").rangeOfCharacter(from: .letters) == nil
}

// %@ %lld %1$@ %.2f %% and Xcode's substitution tokens %#@name@
private let placeholder = try! NSRegularExpression(pattern: #"%(\d+\$)?#@[^@]+@|%(\d+\$)?[-#+0]*(\d+|\*)?(\.\d+)?(hh|h|ll|l|q|z|t|j|L)?[@a-zA-Z%]"#)

func placeholders(_ s: String) -> [String] {
    placeholder.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
}

/** Translation → value for the catalog, or nil when it loses or changes a placeholder. */
func check(_ translation: String, source: String) -> String? {
    // The AI sometimes adds line breaks; a value without them must not get one
    let value = source.contains("\n") ? translation : translation.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    return placeholders(value) == placeholders(source) ? value : nil
}

/** Every stringUnit text of a localization (plain, plural/device variations and substitutions). */
func units(_ node: JSON) -> [String] {
    var out: [String] = []
    if let value = node["stringUnit"]?["value"]?.string { out.append(value) }
    for cases in (node["variations"]?.object ?? [:]).values { for sub in (cases.object ?? [:]).values { out += units(sub) } }
    for sub in (node["substitutions"]?.object ?? [:]).values { out += units(sub) }
    return out
}

func stringUnit(_ value: String) -> JSON { .object(["stringUnit": .object(["state": .string("translated"), "value": .string(value)])]) }

/** key → source localization, for the strings that must be translated. Without one, Xcode uses the key as the text. */
func sources(_ catalog: JSON, sourceLang: String) -> [String: JSON] {
    var out: [String: JSON] = [:]
    for (key, entry) in catalog["strings"]?.object ?? [:] {
        if entry["shouldTranslate"] == .bool(false) || entry["extractionState"] == .string("stale") { continue }
        let source = entry["localizations"]?[sourceLang] ?? stringUnit(key)
        if units(source).allSatisfy(isIgnored) { continue } // nothing to translate: no localization is written
        out[key] = source
    }
    return out
}

// shortcut: CLDR plural categories of common languages (Swift has no Intl.PluralRules); add a language when an app needs it
private let pluralCategories: [String: [String]] = [
    "ja": ["other"], "zh": ["other"], "ko": ["other"], "vi": ["other"], "th": ["other"], "id": ["other"], "ms": ["other"],
    "es": ["one", "many", "other"], "fr": ["one", "many", "other"], "it": ["one", "many", "other"],
    "pt": ["one", "many", "other"], "ca": ["one", "many", "other"],
    "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"], "pl": ["one", "few", "many", "other"],
    "cs": ["one", "few", "many", "other"], "he": ["one", "two", "other"], "ar": ["zero", "one", "two", "few", "many", "other"],
]

func pluralCases(_ lang: String, source: [String: JSON]) -> [String] {
    let base = String(lang.split(separator: "-").first ?? "")
    let cldr = pluralCategories[base] ?? ["one", "other"]
    // Apple accepts "zero" in every language
    return (source["zero"] != nil && !cldr.contains("zero") ? ["zero"] : []) + cldr
}

/**
 * Target localization with the shape of the source one, each text through `translate` (nil = no valid translation).
 * Plurals get the target language's categories, a missing one filled from "other". Nil if any text is missing.
 */
func mirror(_ src: JSON, lang: String, _ translate: (String) -> String?) -> JSON? {
    var out: [String: JSON] = [:]
    if let value = src["stringUnit"]?["value"]?.string {
        guard let t = translate(value) else { return nil }
        out = stringUnit(t).object!
    }
    if let variations = src["variations"]?.object {
        var vs: [String: JSON] = [:]
        for (type, casesJSON) in variations {
            let cases = casesJSON.object ?? [:]
            var target: [String: JSON] = [:]
            for name in type == "plural" ? pluralCases(lang, source: cases) : Array(cases.keys) {
                guard let from = cases[name] ?? cases["other"], let node = mirror(from, lang: lang, translate) else { return nil }
                target[name] = node
            }
            vs[type] = .object(target)
        }
        out["variations"] = .object(vs)
    }
    if let substitutions = src["substitutions"]?.object {
        var subs: [String: JSON] = [:]
        for (name, sub) in substitutions {
            var rest = sub.object ?? [:] // argNum, formatSpecifier
            rest["variations"] = nil
            rest["stringUnit"] = nil
            guard let node = mirror(sub, lang: lang, translate)?.object else { return nil }
            subs[name] = .object(rest.merging(node) { $1 })
        }
        out["substitutions"] = .object(subs)
    }
    return .object(out)
}
