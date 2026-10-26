import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { translate } from '../src/translate.mjs'
import { check, serialize, shortHash } from '../src/xcstrings.mjs'

const quiet = { info() {}, warn() {} }
const su = (value) => ({ stringUnit: { state: 'translated', value } })
const EN = {
  'Hola %@': 'Hello %@',
  'Configuración': 'Settings',
  '%lld viajes': '%lld trips',
  '%lld viaje': '%lld trip',
  'Cerrar': 'Close',
}

function fakeApi(dict) {
  const api = { requests: 0, uploads: 0, tasks: 0 }
  api.validateChanges = async () => (api.uploads ? {} : { x: 1, [shortHash('Localizable.xcstrings')]: 1 })
  api.loadSources = async () => (api.uploads++, 't1')
  api.makeTranslations = async () => (api.tasks++, 't2')
  api.getTranslations = async () => Object.fromEntries(Object.entries(dict).map(([s, t]) => [shortHash(s), t]))
  api.waitTask = async () => true
  return api
}

function setup() {
  const dir = mkdtempSync(join(tmpdir(), 'tp-ios-'))
  const file = join(dir, 'Localizable.xcstrings')
  writeFileSync(file, JSON.stringify({
    sourceLanguage: 'es',
    version: '1.0',
    strings: {
      'Hola %@': { comment: 'Saludo en el inicio' },
      settings_title: { localizations: { es: su('Configuración') } },
      trips: { localizations: { es: { variations: { plural: { one: su('%lld viaje'), other: su('%lld viajes') } } } } },
      'Ruteo': { shouldTranslate: false },
      'Cerrar': {},
    },
  }))
  return { file, cache: join(dir, 'Localizable.translate-projects.json') }
}

test('translates plain, keyed and plural strings into the catalog, keeping comments', async () => {
  const { file, cache } = setup()
  const api = fakeApi(EN)
  await translate(api, file, cache, 'es', ['en', 'pt-BR'], { log: quiet })
  const c = JSON.parse(readFileSync(file, 'utf8'))
  assert.equal(api.uploads, 1)
  assert.deepEqual(c.strings['Hola %@'].localizations.en, su('Hello %@'))
  assert.equal(c.strings['Hola %@'].comment, 'Saludo en el inicio')
  assert.deepEqual(c.strings.settings_title.localizations.en, su('Settings'))
  assert.deepEqual(c.strings.trips.localizations.en.variations.plural, { one: su('%lld trip'), other: su('%lld trips') })
  assert.equal(c.strings.Ruteo.localizations, undefined)
  assert.equal(JSON.parse(readFileSync(cache, 'utf8')).en.version.length, 15)
})

test('pt-BR plurals get "many" from "other"', async () => {
  const { file, cache } = setup()
  await translate(fakeApi(EN), file, cache, 'es', ['pt-BR'], { log: quiet })
  const plural = JSON.parse(readFileSync(file, 'utf8')).strings.trips.localizations['pt-BR'].variations.plural
  assert.deepEqual(Object.keys(plural).sort(), ['many', 'one', 'other'])
  assert.deepEqual(plural.many, plural.other)
})

test('second run with nothing changed skips; manual edits survive; --force overwrites', async () => {
  const { file, cache } = setup()
  await translate(fakeApi(EN), file, cache, 'es', ['en'], { log: quiet })
  const c = JSON.parse(readFileSync(file, 'utf8'))
  c.strings.Cerrar.localizations.en = su('Dismiss')
  writeFileSync(file, JSON.stringify(c))

  const again = fakeApi(EN)
  again.validateChanges = async () => ({})
  await translate(again, file, cache, 'es', ['en'], { log: quiet })
  assert.equal(again.tasks, 0)

  const changed = fakeApi({ ...EN, 'Hola %@': 'Hi %@' })
  changed.validateChanges = async () => ({})
  await translate(changed, file, cache, 'es', ['en'], { log: quiet, force: false })
  await translate(changed, file, cache, 'es', ['en'], { log: quiet, force: true })
  const after = JSON.parse(readFileSync(file, 'utf8'))
  assert.deepEqual(after.strings['Hola %@'].localizations.en, su('Hi %@'))
  assert.deepEqual(after.strings.Cerrar.localizations.en, su('Close'))
})

test('manual edit is kept when the language is retranslated', async () => {
  const { file, cache } = setup()
  await translate(fakeApi(EN), file, cache, 'es', ['en'], { log: quiet })
  const c = JSON.parse(readFileSync(file, 'utf8'))
  c.strings.Cerrar.localizations.en = su('Dismiss')
  writeFileSync(file, JSON.stringify(c))
  const k = JSON.parse(readFileSync(cache, 'utf8'))
  k.en.version = '' // as if the sources had changed
  writeFileSync(cache, JSON.stringify(k))
  await translate(fakeApi(EN), file, cache, 'es', ['en'], { log: quiet })
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')).strings.Cerrar.localizations.en, su('Dismiss'))
})

test('a translation that loses a placeholder is not written', async () => {
  const { file, cache } = setup()
  await translate(fakeApi({ ...EN, 'Hola %@': 'Hello' }), file, cache, 'es', ['en'], { log: quiet })
  const c = JSON.parse(readFileSync(file, 'utf8'))
  assert.equal(c.strings['Hola %@'].localizations, undefined)
  assert.equal(JSON.parse(readFileSync(cache, 'utf8')).en.version, '')
})

test('placeholders and serialization', () => {
  assert.equal(check('Tienes %1$@ y %2$lld', 'You have %1$@ and %2$lld'), 'Tienes %1$@ y %2$lld')
  assert.equal(check('%lld', '%d'), null)
  assert.equal(check('50 % de descuento', '50 % off'), '50 % de descuento')
  assert.equal(check('Hola\nmundo', 'Hello world'), 'Hola mundo')
  assert.equal(serialize({ b: { }, a: 'x' }), '{\n  "a" : "x",\n  "b" : {\n\n  }\n}')
})
