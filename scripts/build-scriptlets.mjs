// Builds uBlock Origin's scriptlets (GPLv3) as resources for Brave's
// adblock-rust, for the iOS app. Run by CI against a pinned uBO release:
//
//   node scripts/build-scriptlets.mjs <uBlock checkout> <output.json>
//
// uBO registers each scriptlet in src/js/resources/scriptlets.js as
// { name, aliases, fn, dependencies, requiresTrust }. adblock-rust takes
// "function-style" resources: the function's source as the content, called
// with the rule's arguments, with helper functions (`*.fn`) as dependencies.
// Trusted scriptlets keep a permission bit, so normal lists can't use them.

import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [, , uboDir, outPath] = process.argv;
if (!uboDir || !outPath) {
  console.error('usage: build-scriptlets.mjs <uBlock checkout> <output.json>');
  process.exit(2);
}

const registry = await import(pathToFileURL(`${uboDir}/src/js/resources/scriptlets.js`).href);
const scriptlets = registry.builtinScriptlets;
if (!Array.isArray(scriptlets) || scriptlets.length < 50) {
  throw new Error(`unexpected scriptlet registry (${scriptlets && scriptlets.length} entries)`);
}

const resources = [];
const taken = new Set();
for (const entry of scriptlets) {
  if (!entry || typeof entry.name !== 'string' || typeof entry.fn !== 'function') { continue; }
  const code = entry.fn.toString();
  const helper = entry.name.endsWith('.fn');
  // adblock-rust calls a scriptlet by its function's name, so a scriptlet
  // must be a named function declaration. Helpers are only pasted in ahead
  // of the calls, so a class (ArglistParser, JSONPath, …) is fine there.
  if (!helper && !/^function\s+[^\s(){}]+\s*\(/.test(code)) {
    console.warn(`skipped ${entry.name}: not a named function declaration`);
    continue;
  }
  const aliases = Array.isArray(entry.aliases) ? entry.aliases : [];
  const names = [entry.name, ...aliases];
  if (names.some(name => taken.has(name))) {
    console.warn(`skipped ${entry.name}: name already used`);
    continue;
  }
  names.forEach(name => taken.add(name));
  const resource = {
    name: entry.name,
    aliases,
    kind: { mime: helper ? 'fn/javascript' : 'application/javascript' },
    content: Buffer.from(code, 'utf8').toString('base64'),
  };
  if (Array.isArray(entry.dependencies) && entry.dependencies.length) {
    resource.dependencies = entry.dependencies;
  }
  if (entry.requiresTrust) { resource.permission = 1; }
  resources.push(resource);
}

writeFileSync(outPath, JSON.stringify(resources));
const trusted = resources.filter(r => r.permission).length;
const helpers = resources.filter(r => r.kind.mime === 'fn/javascript').length;
console.log(`${resources.length} resources (${helpers} helpers, ${trusted} trusted) written to ${outPath}`);
