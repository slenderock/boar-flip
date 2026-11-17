// Runs Boar Flip in a mocked WoW (wowmock.lua) under fengari, a Lua VM in JavaScript.
//   node run.js [--toc file.toc] [--dump dir] [scenario.lua ...]
// Each scenario starts a fresh game: the mock, then the addon's .lua files in .toc order
// (each gets ADDON and the shared ns as ...), then the scenario. With no scenarios given
// it runs every scenario-*.lua here. Exits 1 if a check fails or Lua errors.
// --dump dir writes each scenario's chat and the game calls it made, to compare two
// versions of the addon (diff the dirs).
const path = require('path');
const fs = require('fs');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const args = process.argv.slice(2);
let toc = path.join(__dirname, '..', 'BoarFlip', 'BoarFlip.toc');
const tocAt = args.indexOf('--toc');
if (tocAt >= 0) { toc = path.resolve(args[tocAt + 1]); args.splice(tocAt, 2); }
let dumpDir = null;
const dumpAt = args.indexOf('--dump');
if (dumpAt >= 0) { dumpDir = path.resolve(args[dumpAt + 1]); args.splice(dumpAt, 2); fs.mkdirSync(dumpDir, { recursive: true }); }
const addonDir = path.join(__dirname, '..', 'BoarFlip');
const files = fs.readFileSync(toc, 'utf8').split(/\r?\n/).map(s => s.trim())
  .filter(s => s && !s.startsWith('#') && s.endsWith('.lua'));
const scenarios = args.length ? args.map(a => path.resolve(a))
  : fs.readdirSync(__dirname).filter(f => /^scenario-.*\.lua$/.test(f)).sort().map(f => path.join(__dirname, f));

function newGame() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  // Lua 5.1 names the addon may use that 5.3 dropped.
  lauxlib.luaL_dostring(L, to_luastring('unpack = unpack or table.unpack; __ns = {}'));
  return L;
}

function run(L, file, addonArgs) {
  const code = fs.readFileSync(file);
  if (lauxlib.luaL_loadbuffer(L, code, null, to_luastring('@' + path.basename(file))) !== lua.LUA_OK) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)));
  }
  if (addonArgs) {
    lua.lua_pushstring(L, to_luastring('BoarFlip'));
    lua.lua_getglobal(L, to_luastring('__ns'));
  }
  // A traceback on errors, for the line the error came from.
  lua.lua_getglobal(L, to_luastring('debug'));
  lua.lua_getfield(L, -1, to_luastring('traceback'));
  lua.lua_remove(L, -2);
  const n = addonArgs ? 2 : 0;
  lua.lua_insert(L, -(n + 2));
  const status = lua.lua_pcall(L, n, 0, -(n + 2));
  if (status !== lua.LUA_OK) {
    const msg = to_jsstring(lua.lua_tostring(L, -1));
    lua.lua_pop(L, 2);
    throw new Error(msg);
  }
  lua.lua_pop(L, 1);
}

function dump(L, file) {
  lauxlib.luaL_dostring(L, to_luastring(`
    local lines = {}
    for _, l in ipairs(mock.out) do lines[#lines + 1] = "chat " .. l end
    for _, c in ipairs(mock.calls) do
      local a = {}
      for i, v in ipairs(c.args) do a[i] = type(v) == "table" and "{}" or tostring(v) end
      lines[#lines + 1] = "call " .. c.name .. " " .. table.concat(a, " ")
    end
    __dump = table.concat(lines, "\\n")`));
  lua.lua_getglobal(L, to_luastring('__dump'));
  fs.writeFileSync(file, to_jsstring(lua.lua_tostring(L, -1)) + '\n');
  lua.lua_pop(L, 1);
}

function failures(L) {
  lua.lua_getglobal(L, to_luastring('mock'));
  lua.lua_getfield(L, -1, to_luastring('failures'));
  const n = lua.lua_tonumber(L, -1);
  lua.lua_pop(L, 2);
  return n;
}

let failed = 0;
for (const s of scenarios) {
  console.log('== ' + path.basename(s) + (tocAt >= 0 ? ' (' + path.basename(toc) + ')' : ''));
  const L = newGame();
  try {
    run(L, path.join(__dirname, 'wowmock.lua'), false);
    for (const f of files) run(L, path.join(addonDir, f), true);
    run(L, s, false);
    failed += failures(L);
    if (dumpDir) dump(L, path.join(dumpDir, path.basename(s, '.lua') + '.txt'));
  } catch (e) {
    console.log('  ERROR ' + e.message);
    failed += 1;
  }
}
console.log(failed ? `FAILED (${failed})` : 'ALL PASSED');
process.exit(failed ? 1 : 0);
