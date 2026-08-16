import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/main.ts', import.meta.url), 'utf8');

assert.match(source, /id="import-store-profile"/, 'receipt settings must show an import button');
assert.match(source, /\/api\/print-profile\/import/, 'import button must call the import API');
assert.match(source, /name="languages"/, 'receipt settings must show a language selector');
assert.match(source, /Tiếng Việt \+ 日本語/, 'language selector must offer Vietnamese + Japanese');
assert.match(source, /日本語 \(chỉ tiếng Nhật\)/, 'language selector must offer Japanese-only');
assert.match(source, /template_settings:\s*\{[\s\S]*?languages:\s*[^,]+/, 'saving the form must include languages');
console.log('print-profile language UI: ok');
