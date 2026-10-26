#!/usr/bin/env node
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, basename } from 'node:path'
import { parseArgs } from 'node:util'
import { Api, translate } from '../src/translate.mjs'

const { values: o } = parseArgs({
  options: {
    file: { type: 'string', default: 'Localizable.xcstrings' },
    source: { type: 'string' },
    langs: { type: 'string' },
    'token-file': { type: 'string' },
    force: { type: 'boolean', default: false },
    help: { type: 'boolean', short: 'h' },
  },
})
if (o.help || !o.source || !o.langs) {
  console.log(`Usage: translate-projects-ios --source es --langs en,pt-BR [--file Localizable.xcstrings] [--token-file .translate-projects-token] [--force]
Token: TRANSLATE_PROJECTS_API_KEY or the file given in --token-file.`)
  process.exit(o.help ? 0 : 1)
}
if (!existsSync(o.file)) {
  console.error(`Translate Projects: ${o.file} not found`)
  process.exit(1)
}
// The file may be a plain token or a .env line TRANSLATE_PROJECTS_API_KEY=...
const token = o['token-file'] ? readFileSync(o['token-file'], 'utf8').trim().replace(/^(export\s+)?TRANSLATE_PROJECTS_API_KEY=["']?|["']$/g, '') : process.env.TRANSLATE_PROJECTS_API_KEY
const cacheFile = join(dirname(o.file), basename(o.file, '.xcstrings') + '.translate-projects.json')
try {
  await translate(new Api(token), o.file, cacheFile, o.source, o.langs.split(',').map((l) => l.trim()).filter(Boolean), { force: o.force })
} catch (e) {
  console.error(e.message)
  process.exit(1)
}
