import { createHash } from 'node:crypto'

// Texts the backend never stores (helpers/ignore_list.py), so they never come back translated
export const IGNORED = new Set(['', '.', ',', ':', ';', '...'])

// %@ %lld %1$@ %.2f %% and Xcode's substitution tokens %#@name@
const PLACEHOLDER = /%(\d+\$)?#@[^@]+@|%(\d+\$)?[-#+0]*(\d+|\*)?(\.\d+)?(hh|h|ll|l|q|z|t|j|L)?[@a-zA-Z%]/g

/** SHA-256 → base36, first 15 chars. Must match the backend's helpers/hash_utils.py. */
export const shortHash = (text) => BigInt('0x' + createHash('sha256').update(text).digest('hex')).toString(36).slice(0, 15)

const placeholders = (s) => (s.match(PLACEHOLDER) || []).sort().join('\u0000')

/** Every stringUnit of a localization (plain, plural/device variations and substitutions). */
export function units(node) {
  if (!node || typeof node !== 'object') return []
  const out = node.stringUnit ? [node.stringUnit.value] : []
  for (const cases of Object.values(node.variations || {})) for (const sub of Object.values(cases)) out.push(...units(sub))
  for (const sub of Object.values(node.substitutions || {})) out.push(...units(sub))
  return out
}

/** key → source localization, for the strings that must be translated. Without one, Xcode uses the key as the text. */
export function sources(catalog, sourceLang) {
  const out = {}
  for (const [key, entry] of Object.entries(catalog.strings || {})) {
    if (entry.shouldTranslate === false || entry.extractionState === 'stale') continue
    out[key] = entry.localizations?.[sourceLang] ?? { stringUnit: { state: 'translated', value: key } }
  }
  return out
}

// Apple accepts "zero" in every language; the rest follow CLDR (en: one/other, pt: one/many/other)
const pluralCases = (lang, cases) => [...new Set([...(cases.zero ? ['zero'] : []), ...new Intl.PluralRules(lang).resolvedOptions().pluralCategories])]

/**
 * Target localization with the shape of the source one, each text through `translate` (null = no valid translation).
 * Plurals get the target language's categories, a missing one filled from "other". Null if any text is missing.
 */
export function mirror(src, lang, translate) {
  const out = {}
  if (src.stringUnit) {
    const value = translate(src.stringUnit.value)
    if (value == null) return null
    out.stringUnit = { state: 'translated', value }
  }
  if (src.variations) {
    out.variations = {}
    for (const [type, cases] of Object.entries(src.variations)) {
      out.variations[type] = {}
      for (const name of type === 'plural' ? pluralCases(lang, cases) : Object.keys(cases)) {
        const node = mirror(cases[name] ?? cases.other, lang, translate)
        if (node == null) return null
        out.variations[type][name] = node
      }
    }
  }
  if (src.substitutions) {
    out.substitutions = {}
    for (const [name, sub] of Object.entries(src.substitutions)) {
      const { variations, stringUnit, ...rest } = sub // argNum, formatSpecifier
      const node = mirror({ variations, stringUnit }, lang, translate)
      if (node == null) return null
      out.substitutions[name] = { ...rest, ...node }
    }
  }
  return out
}

/** Translation → value for the catalog, or null when it loses or changes a placeholder. */
export function check(translation, source) {
  // The AI often trims; a value without line breaks must not get one
  const value = source.includes('\n') ? translation : translation.replace(/\r?\n/g, ' ')
  return placeholders(value) === placeholders(source) ? value : null
}

/** Same object regardless of key order, to compare what Xcode saved with what we wrote. */
export const canonical = (v) =>
  v && typeof v === 'object' && !Array.isArray(v)
    ? '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}'
    : JSON.stringify(v)

/** Xcode's own layout (sorted keys, `" : "`), so saving from Xcode does not rewrite the whole file. */
export function serialize(v, indent = '') {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return JSON.stringify(v)
  const inner = indent + '  '
  const keys = Object.keys(v).sort()
  if (!keys.length) return '{\n\n' + indent + '}'
  return '{\n' + keys.map((k) => inner + JSON.stringify(k) + ' : ' + serialize(v[k], inner)).join(',\n') + '\n' + indent + '}'
}
