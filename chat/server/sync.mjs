// Copies the server to its working folder outside OneDrive, where the packages and local secrets are.
//   node chat/server/sync.mjs
// The tool list is taken from docs/assets/chat-tools.js, so the page and the server can never disagree.
import fs from 'node:fs'; import path from 'node:path'; import vm from 'node:vm'; import os from 'node:os'; import crypto from 'node:crypto'; import { fileURLToPath } from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url)), out = process.env.HAPPEN_CHAT || path.join(os.homedir(), 'happen-chat');
const box = vm.createContext({ window: {} }); vm.runInContext(fs.readFileSync(path.join(here, '../../docs/assets/chat-tools.js'), 'utf8'), box);
fs.mkdirSync(path.join(out, 'src'), { recursive: true });
for (const f of fs.readdirSync(path.join(here, 'src'))) fs.copyFileSync(path.join(here, 'src', f), path.join(out, 'src', f));
fs.copyFileSync(path.join(here, 'wrangler.jsonc'), path.join(out, 'wrangler.jsonc'));
fs.writeFileSync(path.join(out, 'src', 'tools.json'), JSON.stringify(box.window.ChatTools.definitions, null, 1));
// a fingerprint of the rules, tools and model settings, kept with each logged question
fs.writeFileSync(path.join(out, 'src', 'rules.json'), JSON.stringify({ version: crypto.createHash('sha256').update(fs.readFileSync(path.join(here, 'src', 'claude.js'), 'utf8').replace(/\r/g, '')).update(JSON.stringify(box.window.ChatTools.definitions)).digest('hex').slice(0, 12) }));
console.log(`copied to ${out}: ${box.window.ChatTools.definitions.length} tools`);
