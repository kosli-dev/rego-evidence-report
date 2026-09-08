// Builds the POC editor into a single self-contained page.
//
//   npm run bundle && npm run editor    ->  dist/editor.html
//
// The template carries the UI; everything it knows about the language comes
// from dist/web.js, which is core/ compiled unchanged. The page reimplements
// no parsing — if the editor and the transpiler ever disagreed about what is a
// rule, the whole premise of showing the classification live would be gone.
//
// The sample policies are the committed ones, read from examples/ rather than
// copied, so the editor cannot open with a policy the test suite does not pin.

import {readFileSync, writeFileSync, mkdirSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')

const SAMPLES = {
	pd: 'examples/prod_deploy_md/policy.md',
	c43: 'examples/control_43_md/policy.md',
	ms: 'examples/multi_subject_md/policy.md',
}

const template = readFileSync(join(HERE, 'index.template.html'), 'utf8')
// `</script` inside a script element ends it, wherever it appears.
const bundle = readFileSync(join(HERE, '..', 'dist', 'web.js'), 'utf8').replaceAll('</script', String.raw`<\/script`)
const samples = Object.fromEntries(
	Object.entries(SAMPLES).map(([key, path]) => [key, readFileSync(join(ROOT, path), 'utf8')]),
)

/** Escape non-ASCII, so the whole page survives being served without a charset.
 *  esbuild already does this for the bundle; a raw em dash in a sample policy
 *  would be corrupted the same way, and a corrupted em dash is a rule that
 *  silently reads as prose. */
const asciiJson = (value) =>
	JSON.stringify(value).replace(/[\u0080-\uffff]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'))

const page = template.replace('__BUNDLE__', () => bundle).replace('__SAMPLES__', () => asciiJson(samples))

mkdirSync(join(HERE, '..', 'dist'), {recursive: true})
const out = join(HERE, '..', 'dist', 'editor.html')
writeFileSync(out, page)
process.stdout.write(`${out}: ${Math.round(page.length / 1024)}KB\n`)
