import { readFileSync, writeFileSync } from 'node:fs'

const file = 'src/background/loginStateWatcher.ts'
const source = readFileSync(file, 'utf8')
const original = 'browser.cookies.onChanged.addListener(({ cookie }) => {'
const guarded = `browser.cookies.onChanged.addListener((changeInfo) => {
    // Safari may deliver an empty cookie event.
    const cookie = changeInfo?.cookie
    if (!cookie || typeof cookie.domain !== 'string')
      return
`
if (source.includes(original)) {
  writeFileSync(file, source.replace(original, guarded))
  console.log('Applied Safari cookie-event compatibility guard')
}
else if (source.includes('const cookie = changeInfo?.cookie')) {
  console.log('Cookie-event compatibility guard already present')
}
else {
  throw new Error('Upstream cookie watcher changed; review the Safari compatibility patch before building')
}
