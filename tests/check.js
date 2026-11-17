// Static checks on the addon's Lua, for what WoW would only show as the addon silently not
// loading (script errors are off in the game):
//   - syntax, as Lua 5.1;
//   - globals: every global name must be a known WoW or Lua one (a new name is usually a
//     local used before it's declared, or a typo);
//   - Lua 5.1's limits: 200 active locals and 60 upvalues per function;
//   - ns, shared between the files: every ns.X read is assigned somewhere, and a top-level
//     `local x = ns.y` only captures what an earlier file (or earlier in the same file) set.
// Usage: node check.js [--toc file.toc]
const path = require('path');
const fs = require('fs');
const luaparse = require('luaparse');

const args = process.argv.slice(2);
let toc = path.join(__dirname, '..', 'BoarFlip', 'BoarFlip.toc');
const tocAt = args.indexOf('--toc');
if (tocAt >= 0) toc = path.resolve(args[tocAt + 1]);
const addonDir = path.join(__dirname, '..', 'BoarFlip');
const files = fs.readFileSync(toc, 'utf8').split(/\r?\n/).map(s => s.trim())
  .filter(s => s && !s.startsWith('#') && s.endsWith('.lua'));

const KNOWN = new Set([
  // Lua
  '_G', 'assert', 'error', 'ipairs', 'pairs', 'next', 'pcall', 'xpcall', 'print', 'select', 'tonumber',
  'tostring', 'type', 'unpack', 'setmetatable', 'getmetatable', 'rawget', 'rawset', 'math', 'string', 'table',
  // WoW
  'date', 'time', 'GetTime', 'GetMoney', 'CreateFrame', 'UIParent', 'GameTooltip', 'MerchantFrame',
  'UIErrorsFrame', 'C_Timer', 'C_AuctionHouse', 'C_Container', 'C_Item', 'C_TradeSkillUI', 'Enum',
  'ItemLocation', 'GetItemInfo', 'GetItemCount', 'NUM_BAG_SLOTS', 'ATTACHMENTS_MAX_RECEIVE',
  'PlaySoundFile', 'GetInboxNumItems', 'GetInboxItem', 'GetInboxInvoiceInfo', 'GetInboxHeaderInfo',
  'TakeInboxMoney', 'TakeInboxItem', 'AutoLootMailItem', 'CheckInbox', 'UnitCastingInfo', 'IsShiftKeyDown',
  'hooksecurefunc', 'SlashCmdList', 'GetProfessions', 'GetProfessionInfo', 'GetNumSkillLines', 'GetSkillLineInfo',
  'GetSpellInfo', 'C_Spell',
  // Boar Flip's own, on purpose: saved variables, the key binding, the slash command.
  'BoarFlipDB', 'BoarFlip_Buy', 'BINDING_NAME_BOARBANDAGES_BUY', 'SLASH_BOARFLIP1',
]);

let problems = 0;
function problem(text) { problems += 1; console.log('  PROBLEM ' + text); }

// ns: name -> { file index, line, top level? } of each assignment; reads and top-level captures.
const nsSets = new Map();
const nsReads = [];
const nsCaptures = [];

files.forEach((file, fileIndex) => {
  const src = fs.readFileSync(path.join(addonDir, file), 'utf8');
  let ast;
  try {
    ast = luaparse.parse(src, { scope: true, locations: true, luaVersion: '5.1' });
  } catch (e) {
    problem(`${file}: syntax: ${e.message}`);
    return;
  }

  // Globals.
  const seen = new Set();
  (function walk(node) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) return node.forEach(walk);
    if (node.type === 'Identifier' && node.isLocal === false && !KNOWN.has(node.name) && !seen.has(node.name)) {
      seen.add(node.name);
      problem(`${file}:${node.loc.start.line}: unknown global ${node.name}`);
    }
    for (const key of Object.keys(node)) {
      if (key === 'loc' || key === 'range') continue;
      if (node.type === 'MemberExpression' && key === 'identifier') continue;
      if (node.type === 'TableKeyString' && key === 'key') continue;
      const v = node[key];
      if (v && typeof v === 'object') walk(v);
    }
  })(ast);

  // ns. depth counts function nesting: 0 is the file's top level.
  const isNs = n => n && n.type === 'MemberExpression' && n.base.type === 'Identifier' && n.base.name === 'ns';
  function setName(name, line, depth) {
    const list = nsSets.get(name) || [];
    list.push({ fileIndex, line, top: depth === 0 });
    nsSets.set(name, list);
  }
  (function walk(node, depth, target) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) return node.forEach(n => walk(n, depth, false));
    if (node.type === 'FunctionDeclaration') {
      if (isNs(node.identifier)) setName(node.identifier.identifier.name, node.loc.start.line, depth);
      node.parameters.forEach(p => walk(p, depth + 1, false));
      node.body.forEach(s => walk(s, depth + 1, false));
      return;
    }
    if (node.type === 'AssignmentStatement') {
      node.variables.forEach(v => {
        if (isNs(v)) setName(v.identifier.name, v.loc.start.line, depth);
        else walk(v, depth, true);
      });
      node.init.forEach(n => walk(n, depth, false));
      return;
    }
    if (node.type === 'LocalStatement' && depth === 0) {
      node.init.forEach(n => {
        if (isNs(n)) nsCaptures.push({ name: n.identifier.name, fileIndex, line: n.loc.start.line, file });
      });
    }
    if (isNs(node) && !target) nsReads.push({ name: node.identifier.name, file, line: node.loc.start.line });
    for (const key of Object.keys(node)) {
      if (key === 'loc' || key === 'range') continue;
      if (node.type === 'MemberExpression' && key === 'identifier') continue;
      if (node.type === 'TableKeyString' && key === 'key') continue;
      const v = node[key];
      if (v && typeof v === 'object') walk(v, depth, false);
    }
  })(ast, 0, false);

  // Limits.
  const funcs = [];
  let scopes = [], cur = null;
  const newFunc = (parent, line, name) => { const f = { parent, line, name, upvals: new Set(), active: 0, maxActive: 0 }; funcs.push(f); return f; };
  const pushScope = () => scopes.push({ func: cur, vars: new Map() });
  const popScope = () => { const s = scopes.pop(); s.func.active -= s.vars.size; };
  const declare = name => {
    const s = scopes[scopes.length - 1];
    if (!s.vars.has(name)) s.func.active += 1;
    s.vars.set(name, { name });
    if (s.func.active > s.func.maxActive) s.func.maxActive = s.func.active;
  };
  const resolve = name => {
    for (let i = scopes.length - 1; i >= 0; i--) {
      const s = scopes[i];
      if (s.vars.has(name)) {
        const decl = s.vars.get(name);
        for (let f = cur; f && f !== s.func; f = f.parent) f.upvals.add(decl);
        return;
      }
    }
  };
  function expr(n) {
    if (!n) return;
    switch (n.type) {
      case 'Identifier': resolve(n.name); break;
      case 'MemberExpression': expr(n.base); break;
      case 'IndexExpression': expr(n.base); expr(n.index); break;
      case 'CallExpression': expr(n.base); n.arguments.forEach(expr); break;
      case 'TableCallExpression': expr(n.base); expr(n.arguments); break;
      case 'StringCallExpression': expr(n.base); break;
      case 'TableConstructorExpression': n.fields.forEach(f => { if (f.type === 'TableKey') expr(f.key); expr(f.value); }); break;
      case 'BinaryExpression': case 'LogicalExpression': expr(n.left); expr(n.right); break;
      case 'UnaryExpression': expr(n.argument); break;
      case 'FunctionDeclaration': func(n, 'anonymous'); break;
    }
  }
  function func(n, name) {
    const saved = cur;
    cur = newFunc(saved, n.loc.start.line, name);
    pushScope();
    n.parameters.forEach(p => { if (p.type === 'Identifier') declare(p.name); });
    n.body.forEach(stmt);
    popScope();
    cur = saved;
  }
  function block(body) { pushScope(); body.forEach(stmt); popScope(); }
  function stmt(n) {
    switch (n.type) {
      case 'LocalStatement': n.init.forEach(expr); n.variables.forEach(v => declare(v.name)); break;
      case 'AssignmentStatement': n.variables.forEach(expr); n.init.forEach(expr); break;
      case 'CallStatement': expr(n.expression); break;
      case 'FunctionDeclaration':
        if (n.isLocal) { declare(n.identifier.name); func(n, n.identifier.name); }
        else { if (n.identifier) expr(n.identifier); func(n, 'function'); }
        break;
      case 'IfStatement': n.clauses.forEach(c => { if (c.condition) expr(c.condition); block(c.body); }); break;
      case 'WhileStatement': expr(n.condition); block(n.body); break;
      case 'DoStatement': block(n.body); break;
      case 'RepeatStatement': pushScope(); n.body.forEach(stmt); expr(n.condition); popScope(); break;
      case 'ForNumericStatement': expr(n.start); expr(n.end); expr(n.step); pushScope(); declare(n.variable.name); n.body.forEach(stmt); popScope(); break;
      case 'ForGenericStatement': n.iterators.forEach(expr); pushScope(); n.variables.forEach(v => declare(v.name)); n.body.forEach(stmt); popScope(); break;
      case 'ReturnStatement': n.arguments.forEach(expr); break;
    }
  }
  cur = newFunc(null, 1, 'main chunk');
  pushScope();
  ast.body.forEach(stmt);
  const top = funcs.reduce((a, f) => (f.maxActive > a.maxActive ? f : a));
  const upv = funcs.reduce((a, f) => (f.upvals.size > a.upvals.size ? f : a));
  console.log(`  ${file}: ${src.split('\n').length} lines; most locals ${top.maxActive}/200 (line ${top.line}), most upvalues ${upv.upvals.size}/60 (line ${upv.line})`);
  funcs.filter(f => f.maxActive > 200 || f.upvals.size > 60)
    .forEach(f => problem(`${file}:${f.line}: over Lua's limits (${f.maxActive} locals, ${f.upvals.size} upvalues)`));
});

for (const r of nsReads) {
  if (!nsSets.has(r.name)) problem(`${r.file}:${r.line}: ns.${r.name} is read but never set`);
}
for (const c of nsCaptures) {
  const ok = (nsSets.get(c.name) || []).some(s => s.top && (s.fileIndex < c.fileIndex || (s.fileIndex === c.fileIndex && s.line < c.line)));
  if (!ok) problem(`${c.file}:${c.line}: local = ns.${c.name} runs before ns.${c.name} is set at load`);
}

console.log(problems ? `CHECKS FAILED (${problems})` : 'CHECKS PASSED');
process.exit(problems ? 1 : 0);
