# Translate Projects for iOS

Translates the String Catalog (`Localizable.xcstrings`) of an iOS/macOS app with [Translate Projects](https://translateprojects.dev), from the terminal. The translations are written into the same catalog, so Xcode and `String(localized:)` / `Text("...")` work as usual.

## Requirements

- Node.js 22.4 or newer (`brew install node`).
- A Translate Projects project with its API token, its base language equal to `--source`, and an AI model configured.

## Usage

```bash
npx translate-projects-ios --source es --langs en,pt-BR --file MyApp/Localizable.xcstrings --token-file .translate-projects-token
npx translate-projects-ios ... --force   # retranslate every language
```

- Token: `TRANSLATE_PROJECTS_API_KEY`, or `--token-file` with the token alone or a `TRANSLATE_PROJECTS_API_KEY=...` line. Never commit it (add the file to `.gitignore`).
- `--file` defaults to `Localizable.xcstrings` in the current folder.

Commit the catalog and `Localizable.translate-projects.json` (the cache, next to the catalog). Building the app never calls the API.

## What it respects

- `%@`, `%lld`, `%1$@`, `%.2f`, `%#@name@`: a translation that loses or changes one is not written (the app falls back to the source text).
- Plurals and device variations, and substitutions; each target language gets its own plural categories (`pt-BR`: one, many, other).
- Strings marked "Don't translate" (`shouldTranslate: false`) and stale strings are skipped. Comments are kept.
- **Manual edits**: a translation you change in Xcode is kept on the next runs until its source text changes. Translations you already had before the first run are kept too. `--force` overwrites them.

## Cache

- Nothing changed in the source language: one request, no upload, no translation.
- Some texts changed: they are uploaded once and only the languages that are out of date are translated again; the server reuses what it already has.
- A language with texts the server could not translate is retried on the next run. A cut run resumes.

## License

MIT
