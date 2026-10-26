import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { basename } from 'node:path'
import { IGNORED, canonical, check, mirror, serialize, shortHash, sources, units } from './xcstrings.mjs'

export const API_URL = 'https://api.translateprojects.dev'
const RETRY_STATUS = new Set([429, 500, 502, 503, 504, 524])
// shortcut: the backend has no "ios" type_project yet; switch when it is added to seeders/type_projects.py
const TYPE_PROJECT = 'json'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export class Api {
  constructor(token, { baseUrl = API_URL, log = console, pollInterval = 60_000, reconnectDelay = 5_000 } = {}) {
    Object.assign(this, { token, baseUrl, log, pollInterval, reconnectDelay, requests: 0, timeout: 60_000 })
  }

  validateChanges = (fileHashes) => this.data('POST', '/v1/translations/validate-changes-files', {}, fileHashes).then((d) => d || {})
  loadSources = (texts, sourceLang, routeFile, version) =>
    this.data('POST', '/v1/translations/load-sources', { source_lang: sourceLang, route_file: routeFile, type_project: TYPE_PROJECT, cache_hash: version }, texts).then((d) => d?.task_id)
  makeTranslations = (sourceLang, targetLang, routeFile, version) =>
    this.data('POST', '/v1/translations/', { source_lang: sourceLang, target_lang: targetLang, route_file: routeFile, cache_hash: version }).then((d) => d?.task_id)
  getTranslations = (targetLang) => this.data('GET', '/v1/translations/language-project', { target_lang: targetLang }).then((d) => d || {})

  /** Calls the API retrying network errors, 429 and 5xx with backoff; any other error throws. */
  async data(method, path, params = {}, body) {
    if (!this.token) throw new Error('MISSING_API_KEY: set TRANSLATE_PROJECTS_API_KEY or pass --token-file')
    const url = `${this.baseUrl}${path}` + (Object.keys(params).length ? '?' + new URLSearchParams(params) : '')
    for (let attempt = 1; attempt <= 3; attempt++) {
      if (attempt > 1) await sleep(1000 << (attempt - 2))
      this.requests++
      let res
      try {
        res = await fetch(url, {
          method,
          headers: { Authorization: `Token ${this.token}`, 'Content-Type': 'application/json', Accept: 'application/json' },
          body: body == null ? undefined : JSON.stringify(body),
          signal: AbortSignal.timeout(this.timeout),
        })
      } catch (e) {
        this.log.warn(`Translate Projects: request failed: ${e.message} (attempt ${attempt}/3)`)
        continue
      }
      if (res.status === 200) {
        const json = await res.json()
        if (json.status && json.status !== 'SUCCESS' && json.message) this.log.warn(`Translate Projects: ${json.error ?? json.code ?? json.status}: ${json.message}`)
        return json.data
      }
      if (RETRY_STATUS.has(res.status)) {
        this.log.warn(`Translate Projects: API ${res.status} (attempt ${attempt}/3), retrying...`)
        continue
      }
      const text = await res.text()
      let detail = text.slice(0, 200)
      try {
        const e = JSON.parse(text)
        detail = `${e.code ?? ''} ${e.message ?? ''}`.trim()
      } catch {}
      throw new Error(`Translate Projects API error (${res.status}): ${detail}`)
    }
    throw new Error(`Translate Projects: max retries reached for ${path}`)
  }

  /**
   * Resolves true when the task reports 100 % or `isDone()` says so. A dropped socket is reconnected; it only gives up
   * after `idleTimeout` ms without any progress, resolving false (never throws).
   */
  async waitTask(taskId, idleTimeout, isDone = async () => false, onProgress = () => {}) {
    const url = `${this.baseUrl.replace(/^http/, 'ws')}/ws/progress/${taskId}/`
    let last = Date.now(), lastCheck = 0, finished = false, ws = null, open = false, reconnectAt = 0
    try {
      while (!finished) {
        const now = Date.now()
        if (!open && now >= reconnectAt) {
          if (ws) this.log.warn('Translate Projects: progress connection lost, reconnecting...')
          open = true
          reconnectAt = now + this.reconnectDelay
          ws = new WebSocket(url)
          ws.onmessage = (e) => {
            last = Date.now()
            const progress = Number(JSON.parse(e.data)?.progress)
            if (Number.isNaN(progress)) return
            onProgress(progress)
            if (progress >= 100) finished = true
          }
          ws.onclose = ws.onerror = () => (open = false)
        }
        if (now - last > idleTimeout) {
          this.log.warn(`Translate Projects: no progress for ${Math.round(idleTimeout / 1000)}s on task ${taskId}, continuing.`)
          return false
        }
        if (now - Math.max(last, lastCheck) > this.pollInterval) {
          lastCheck = now
          if (await isDone().catch(() => false)) return true
        }
        await sleep(100)
      }
      return true
    } finally {
      if (ws) (ws.onclose = ws.onerror = ws.onmessage = null), ws.close()
    }
  }
}

/** Logs "en 40 % (1611/4028 texts)" every 10 %, like the other packages. */
function progress(log, label, total) {
  let lastStep = -1
  return (percent) => {
    const step = Math.min(Math.floor(percent / 10), 10)
    if (step > lastStep) {
      lastStep = step
      log.info(`Translate Projects: ${label} ${Math.floor(percent)} % (${Math.floor((percent * total) / 100)}/${total} texts)`)
    }
  }
}

/**
 * Translates the source language of a String Catalog (.xcstrings) into `targetLangs`, in the same file.
 * A localization that differs from what this tool last wrote is a manual edit (or Xcode's) and is kept until its
 * source changes. `cacheFile` remembers, per language, the version and what was written. A cut run resumes.
 */
export async function translate(api, file, cacheFile, sourceLang, targetLangs, { force = false, log = console } = {}) {
  const catalog = JSON.parse(readFileSync(file, 'utf8'))
  if (catalog.sourceLanguage && catalog.sourceLanguage !== sourceLang)
    throw new Error(`Translate Projects: ${basename(file)} has sourceLanguage "${catalog.sourceLanguage}", not "${sourceLang}"`)
  const srcs = sources(catalog, sourceLang)
  // Keyed by the text hash, like the backend does, so an edited text never comes back with a stale translation
  const texts = Object.fromEntries(Object.values(srcs).flatMap(units).filter((t) => !IGNORED.has(t.trim())).map((t) => [shortHash(t), t]))
  const version = shortHash(JSON.stringify(Object.keys(texts).sort()))
  const routeFile = basename(file)
  log.info(`Translate Projects: ${Object.keys(srcs).length} strings (${Object.keys(texts).length} texts) in ${sourceLang}`)
  api.timeout = 60_000 + Object.keys(texts).length * 100
  // Queued behind other tasks, a task can stay silent for a while; bigger projects queue longer
  const idle = (300 + Object.keys(texts).length / 5) * 1000

  const fileHash = shortHash(routeFile)
  const uploaded = async () => !(fileHash in (await api.validateChanges({ [fileHash]: version })))
  const upload = !(await uploaded())
  if (upload) {
    log.info(`Translate Projects: uploading ${Object.keys(texts).length} texts...`)
    const task = await api.loadSources(texts, sourceLang, routeFile, version)
    if (!task) throw new Error('Translate Projects: sources upload failed')
    // Upload progress comes every 1 %, so a minute of silence means it ended
    await api.waitTask(task, 60_000, uploaded, progress(log, 'upload', Object.keys(texts).length))
  } else {
    log.info('Translate Projects: sources unchanged, upload skipped')
  }

  const cache = existsSync(cacheFile) ? JSON.parse(readFileSync(cacheFile, 'utf8')) : {}
  const has = (lang) => Object.values(catalog.strings || {}).some((e) => e.localizations?.[lang])
  const pending = targetLangs.filter((lang) => lang !== sourceLang).filter((lang) => {
    const upToDate = !force && cache[lang]?.version === version && has(lang)
    if (upToDate) log.info(`Translate Projects: ${lang} is up to date, skipped`)
    return !upToDate
  })
  const save = () => {
    writeFileSync(file, serialize(catalog) + '\n')
    writeFileSync(cacheFile, JSON.stringify(Object.fromEntries(Object.entries(cache).sort()), null, 2) + '\n')
  }
  // Saved per language, so a cut run keeps the languages that finished
  await Promise.all(pending.map(async (lang) => {
    cache[lang] = await translateLanguage(api, catalog, srcs, texts, version, sourceLang, lang, cache[lang], { idle, upload, force, log, routeFile })
    save()
  }))
  log.info(`Translate Projects: done, ${api.requests} HTTP requests`)
}

async function translateLanguage(api, catalog, srcs, texts, version, sourceLang, lang, previous, { idle, upload, force, log, routeFile }) {
  const complete = (byHash) => Object.keys(texts).every((h) => h in byHash)
  // After an upload the translation task must run anyway: with cache_hash it marks every text of the file with
  // this version, otherwise validate-changes keeps reporting the file as changed
  let byHash = upload ? {} : await api.getTranslations(lang)
  if (!upload && complete(byHash)) {
    log.info(`Translate Projects: ${lang} already translated on the server, downloading`)
  } else {
    log.info(`Translate Projects: ${lang} translating ${Object.keys(texts).length} texts (the server reuses what it already has)...`)
    const task = await api.makeTranslations(sourceLang, lang, routeFile, version)
    if (task) await api.waitTask(task, idle, async () => complete(await api.getTranslations(lang)), progress(log, lang, Object.keys(texts).length))
    byHash = await api.getTranslations(lang)
  }

  const written = previous?.keys ?? {} // key → [source, output], both canonical
  const keys = {}
  let translated = 0, manual = 0, missing = 0
  for (const [key, src] of Object.entries(srcs)) {
    const entry = catalog.strings[key] ?? (catalog.strings[key] = {})
    const current = entry.localizations?.[lang]
    const before = written[key]
    const source = canonical(src)
    // Manual = differs from what we last wrote for this same source. A key the cache does not know is new, never
    // manual; only on the first run of a language (no cache) are existing values kept. --force overwrites them all.
    const manualEdit = !force && current && (before ? before[0] === source && canonical(current) !== before[1] : previous == null)
    if (manualEdit) {
      manual++
      keys[key] = [source, before?.[1] ?? '']
      continue
    }
    const missed = []
    const value = mirror(src, lang, (text) => {
      if (IGNORED.has(text.trim())) return text
      const t = byHash[shortHash(text)]
      const ok = t == null ? null : check(t, text)
      if (ok == null) missed.push(t == null ? null : text)
      return ok
    })
    if (value) {
      entry.localizations = { ...entry.localizations, [lang]: value }
      keys[key] = [source, canonical(value)]
      translated++
    } else {
      for (const text of missed.filter(Boolean)) log.warn(`Translate Projects: ${lang}: placeholders changed, skipped "${text}"`)
      missing++
    }
  }
  log.info(`Translate Projects: ${lang} → ${routeFile} (${translated} translated, ${manual} manual kept, ${missing} missing)`)
  if (missing) log.warn(`Translate Projects: ${lang}: ${missing} strings without translation, run again to resume. Check that the project has an AI model and API key configured.`)
  return { version: missing ? '' : version, keys }
}
