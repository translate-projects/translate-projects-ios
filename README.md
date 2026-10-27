# Translate Projects for iOS

Translates the String Catalog (`Localizable.xcstrings`) of an iOS/macOS app with [Translate Projects](https://translateprojects.dev). The translations are written into the same catalog, so Xcode, `Text("...")` and `String(localized:)` work as usual. Swift package with no dependencies: an Xcode / SwiftPM command plugin and a command-line tool.

## Requirements

- Xcode 15 or newer (Swift 5.9+).
- A Translate Projects project with its API token, its base language equal to your catalog's source language, and an AI model configured.

## Setup

1. Xcode → File → Add Package Dependencies → `https://github.com/translate-projects/translate-projects-ios`. You don't need to add it to any target.
2. `translate-projects.json` next to your `.xcodeproj` (or `Package.swift`):

```json
{
  "sourceLang": "es",
  "targetLangs": ["en", "pt-BR"],
  "file": "MyApp/Localizable.xcstrings",
  "tokenFile": ".translate-projects-token"
}
```

`file` is optional when the project has a single `.xcstrings`. The token file holds the project token alone or a `TRANSLATE_PROJECTS_API_KEY=...` line; add it to `.gitignore`. Instead of `tokenFile` you can set `TRANSLATE_PROJECTS_API_KEY`.

## Usage

- **Xcode**: right-click the project in the navigator → **TranslateProjects**. Allow writing and network access when Xcode asks.
- **SwiftPM package**: `swift package --allow-writing-to-package-directory --allow-network-connections all translate`
- **Terminal / CI**: `swift run --package-path /path/to/translate-projects-ios translate-projects-ios --directory . [--force]`, or with [Mint](https://github.com/yonaskolb/Mint): `mint run translate-projects/translate-projects-ios`.

Every setting is also a flag: `--source es --langs en,pt-BR --file ... --token-file ...`. `--force` retranslates every language.

Commit the catalog and `Localizable.translate-projects.json` (the cache, next to the catalog). Building the app never calls the API.

## What it respects

- `%@`, `%lld`, `%1$@`, `%.2f`, `%#@name@`: a translation that loses or changes one is not written (the app falls back to the source text).
- Plural and device variations and substitutions; each language gets its own plural categories (`pt-BR`: one, many, other).
- Strings marked "Don't translate" and stale strings are skipped. Comments are kept.
- **Manual edits**: a translation you change in Xcode is kept on the next runs until its source text changes. Translations you already had before the first run are kept too. `--force` overwrites them.

## Cache

- Nothing changed in the source language: one request, no upload, no translation.
- Some texts changed: they are uploaded once and only the languages that are out of date are translated again; the server reuses what it already has.
- A language with texts the server could not translate is retried on the next run. A cut run resumes.

## License

MIT
