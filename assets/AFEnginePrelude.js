// AFEnginePrelude.js — AppForge Live runtime. Shared by the AppForge preview, the generated
// wrapper apps and the headless tests. Talks to the host only through the __native object.
var state = {};
var screen = { width: 390, height: 844 };
var __af = { b: [], a: [], errs: {}, errList: [], timers: {}, cbs: {}, tid: 1, motionFn: null };
function __err(msg) {
  msg = String(msg);
  if (__af.errs[msg]) return;
  __af.errs[msg] = 1;
  __af.errList.push(msg);
  try { __native.error(msg); } catch (e) {}
}
function __compileExpr(src) {
  try { __af.b.push(new Function('item', 'index', '__s', 'with(__s){ return (' + src + '\n); }')); return __af.b.length - 1; }
  catch (e) { __err('Expresie invalidă «' + src + '»: ' + e.message); return -1; }
}
function __compileAction(src) {
  try { __af.a.push(new Function('item', 'index', '__s', 'value', 'with(__s){ ' + src + '\n }')); return __af.a.length - 1; }
  catch (e) { __err('Acțiune invalidă «' + src + '»: ' + e.message); return -1; }
}
function __evalExpr(i, item, index) {
  if (i < 0) return null;
  try { var v = __af.b[i](item, index, state); return v === undefined ? null : v; }
  catch (e) { __err('Eroare în expresie: ' + e.message); return null; }
}
function __runAction(i, item, index, value) {
  if (i < 0) return;
  try { __af.a[i](item, index, state, value); }
  catch (e) { __err('Eroare în acțiune: ' + e.message); }
  __changed();
}
function __changed() { try { __native.refresh(); } catch (e) {} }
// "Scor: {{score}}" -> JS expression string
function __template(s) {
  s = String(s);
  if (s.indexOf('{{') < 0) return null;
  var parts = [], i = 0;
  while (i < s.length) {
    var a = s.indexOf('{{', i);
    if (a < 0) { parts.push(JSON.stringify(s.slice(i))); break; }
    if (a > i) parts.push(JSON.stringify(s.slice(i, a)));
    var b = s.indexOf('}}', a + 2);
    if (b < 0) { parts.push(JSON.stringify(s.slice(a))); break; }
    parts.push('__str(' + s.slice(a + 2, b) + ')');
    i = b + 2;
  }
  return parts.length ? parts.join(' + ') : '""';
}
function __str(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'number') return (Math.round(v * 1e6) / 1e6).toString();
  if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
  return String(v);
}
// ---- timers ----
function setTimeout(fn, ms) { var id = __af.tid++; __af.timers[id] = fn; __native.timer(id, Math.max(0, +ms || 0), false); return id; }
function setInterval(fn, ms) { var id = __af.tid++; __af.timers[id] = fn; __native.timer(id, Math.max(16, +ms || 16), true); return id; }
function clearTimeout(id) { if (id == null) return; delete __af.timers[id]; __native.cancelTimer(+id); }
var clearInterval = clearTimeout;
function every(ms, fn) { return setInterval(fn, ms); }
function after(ms, fn) { return setTimeout(fn, ms); }
function __fireTimer(id, repeat) {
  var f = __af.timers[id];
  if (!f) { __native.cancelTimer(+id); return; }
  if (!repeat) delete __af.timers[id];
  try { if (typeof f === 'function') f(); else (new Function(String(f)))(); }
  catch (e) { __err('Eroare în timer: ' + e.message); }
  __changed();
}
function __cb(fn) { var id = __af.tid++; __af.cbs[id] = fn; return id; }
function __fireCb(id, v) {
  var f = __af.cbs[id]; delete __af.cbs[id];
  if (typeof f === 'function') { try { f(v); } catch (e) { __err('Eroare: ' + e.message); } }
  __changed();
}
// ---- app API ----
function go(id) { __native.go(String(id)); }
function back() { __native.back(); }
function alert(t, m) { __native.alert(t == null ? '' : String(t), m == null ? '' : String(m)); }
function confirm(t, m, fn) { __native.confirm(t == null ? '' : String(t), m == null ? '' : String(m), __cb(fn)); }
function ask(t, m, def, fn) {
  if (typeof def === 'function') { fn = def; def = ''; }
  __native.ask(t == null ? '' : String(t), m == null ? '' : String(m), def == null ? '' : String(def), __cb(fn));
}
function haptic(k) { __native.haptic(String(k || 'light')); }
function vibrate() { __native.haptic('heavy'); }
function sound(k) { __native.sound(String(k == null ? 'tap' : k)); }
function speak(t, lang) { __native.speak(String(t), String(lang || 'ro-RO')); }
function tone(f, ms, vol) { __native.tone(+f || 880, +ms || 200, vol == null ? 0.5 : +vol); }
function beep() { tone(880, 150, 0.5); }
function toast(t) { __native.toast(String(t)); }
function share(t) { __native.share(String(t)); }
function copy(t) { __native.copy(String(t)); }
function openURL(u) { __native.open(String(u)); }
var store = {
  get: function (k, d) {
    var s = __native.storeGet(String(k));
    if (s === null || s === undefined || s === '') return d === undefined ? null : d;
    try { return JSON.parse(s); } catch (e) { return d === undefined ? null : d; }
  },
  set: function (k, v) { __native.storeSet(String(k), JSON.stringify(v === undefined ? null : v)); },
  remove: function (k) { __native.storeSet(String(k), ''); }
};
var motion = {
  start: function (fn, hz) { __af.motionFn = fn; __native.motionStart(+hz || 30); },
  stop: function () { __af.motionFn = null; __native.motionStop(); }
};
function __motion(d) {
  var f = __af.motionFn;
  if (f) { try { f(d); } catch (e) { __err('Eroare în motion: ' + e.message); motion.stop(); } }
  __changed();
}
var console = { log: function () { __native.log(Array.prototype.map.call(arguments, __str).join(' ')); } };
console.error = console.warn = console.info = console.log;
function random(a, b) { if (b === undefined) { b = a; a = 0; } return Math.floor(Math.random() * (b - a + 1)) + a; }
function now() { return Date.now(); }
function pad(n, w) { n = String(Math.floor(Math.abs(n))); while (n.length < (w || 2)) n = '0' + n; return n; }
function fmtTime(ms, cs) {
  ms = Math.max(0, +ms || 0);
  var m = Math.floor(ms / 60000), s = Math.floor(ms / 1000) % 60, c = Math.floor(ms / 10) % 100;
  return pad(m) + ':' + pad(s) + (cs ? '.' + pad(c) : '');
}
// ---- spec model ----
var __TYPES = {
  vstack: 1, hstack: 1, zstack: 1, scroll: 1, grid: 1, spacer: 1, divider: 1, text: 1, button: 1, image: 1,
  input: 1, textarea: 1, toggle: 1, slider: 1, stepper: 1, segmented: 1, progress: 1, list: 1, canvas: 1, box: 1
};
var __ALIAS = { label: 'text', textfield: 'input', 'switch': 'toggle', column: 'vstack', row: 'hstack', stack: 'vstack', view: 'vstack' };
var __CONTAINERS = { vstack: 1, hstack: 1, zstack: 1, scroll: 1, grid: 1, canvas: 1 };
// props whose value is a JS expression (not a template)
var __EXPR_PROPS = { visible: 1, enabled: 1, items: 1, value: 1, x: 1, y: 1, rotation: 1, scale: 1 };
var __ACTION_PROPS = { onTap: 1, onChange: 1, onLongPress: 1, onAppear: 1, onLoad: 1, action: 1, onSubmit: 1, onDrag: 1 };
var __COLOR_NAMES = { red: 1, green: 1, blue: 1, orange: 1, yellow: 1, pink: 1, purple: 1, teal: 1, indigo: 1, brown: 1, gray: 1, grey: 1, mint: 1, cyan: 1,
  black: 1, white: 1, clear: 1, transparent: 1, label: 1, secondary: 1, background: 1, secondaryBackground: 1, groupedBackground: 1, tint: 1, accent: 1, separator: 1 };
function __normType(t) { t = String(t || ''); return __ALIAS[t] || t; }
function __isColor(c) {
  if (c == null || c === '') return true;
  c = String(c);
  if (c.indexOf('{{') >= 0) return true;
  if (/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(c)) return true;
  if (/^(rgb|rgba)\(/.test(c)) return true;
  if (/^system[A-Z]/.test(c)) return true;
  return !!__COLOR_NAMES[c];
}
function __eachNode(node, fn, path) {
  if (!node || typeof node !== 'object') return;
  fn(node, path);
  var kids = node.children;
  if (Array.isArray(kids)) for (var i = 0; i < kids.length; i++) __eachNode(kids[i], fn, path + '.children[' + i + ']');
  if (node.row) __eachNode(node.row, fn, path + '.row');
}
function __validate(json) {
  var errs = [];
  var spec;
  try { spec = typeof json === 'string' ? JSON.parse(json) : json; } catch (e) { return ['JSON invalid: ' + e.message]; }
  if (!spec || typeof spec !== 'object') return ['Spec-ul trebuie să fie un obiect JSON.'];
  if (!Array.isArray(spec.screens) || !spec.screens.length) errs.push('Lipsește "screens" (listă cu cel puțin un ecran).');
  var ids = {}, screens = {};
  (spec.screens || []).forEach(function (s, i) {
    if (!s || typeof s !== 'object') { errs.push('screens[' + i + '] nu e obiect.'); return; }
    if (!s.id) errs.push('screens[' + i + '] nu are "id".');
    else if (screens[s.id]) errs.push('Ecran duplicat: ' + s.id);
    else screens[s.id] = 1;
    if (!s.body || typeof s.body !== 'object' || Array.isArray(s.body)) errs.push('Ecranul ' + (s.id || i) + ' nu are "body" (un nod, ex. vstack).');
    if (!__isColor(s.background)) errs.push('Culoare invalidă pe ecranul ' + s.id + ': ' + s.background);
    (s.navButtons || []).forEach(function (b, j) {
      if (!b || (!b.title && !b.sf)) errs.push('navButtons[' + j + '] pe ' + s.id + ' are nevoie de "title" sau "sf".');
      if (b && b.action) __compileAction(String(b.action));
    });
    if (s.onAppear) __compileAction(String(s.onAppear));
    if (s.title) { var tt = __template(s.title); if (tt) __compileExpr(tt); }
    __eachNode(s.body, function (n, path) {
      var t = __normType(n.type);
      var where = (s.id || 'ecran') + path + (n.id ? ' (#' + n.id + ')' : '');
      if (!__TYPES[t]) { errs.push('Tip necunoscut "' + n.type + '" la ' + where + '. Tipuri: ' + Object.keys(__TYPES).join(', ')); return; }
      if (n.id) { if (ids[n.id]) errs.push('id duplicat: ' + n.id); ids[n.id] = 1; }
      if (n.children !== undefined && !Array.isArray(n.children)) errs.push('"children" trebuie să fie listă la ' + where);
      if (n.children && !__CONTAINERS[t]) errs.push('"' + t + '" nu poate avea children la ' + where);
      if (t === 'button' && n.title == null && !n.sf) errs.push('Butonul de la ' + where + ' are nevoie de "title" sau "sf".');
      if (t === 'list') {
        if (!n.items) errs.push('Lista de la ' + where + ' are nevoie de "items" (expresie, ex. "todos").');
        if (!n.row || typeof n.row !== 'object') errs.push('Lista de la ' + where + ' are nevoie de "row" (un nod).');
      }
      if ((t === 'input' || t === 'textarea' || t === 'toggle' || t === 'slider' || t === 'stepper' || t === 'segmented') && !n.bind)
        errs.push('"' + t + '" de la ' + where + ' are nevoie de "bind" (cheia din state).');
      if (t === 'segmented' && !Array.isArray(n.options)) errs.push('segmented de la ' + where + ' are nevoie de "options" (listă).');
      ['color', 'background', 'tint', 'borderColor', 'textColor'].forEach(function (k) {
        if (n[k] != null && !__isColor(n[k])) errs.push('Culoare invalidă ' + k + '="' + n[k] + '" la ' + where);
      });
      Object.keys(n).forEach(function (k) {
        var v = n[k];
        if (__ACTION_PROPS[k]) { if (typeof v !== 'string') errs.push(k + ' trebuie să fie text JS la ' + where); else __compileAction(v); }
        else if (__EXPR_PROPS[k] && typeof v === 'string') __compileExpr(v);
        else if (typeof v === 'string' && v.indexOf('{{') >= 0) { var tp = __template(v); if (tp) __compileExpr(tp); }
      });
    });
  });
  if (spec.start && !screens[spec.start]) errs.push('"start" indică un ecran inexistent: ' + spec.start);
  if (spec.tabs !== undefined) {
    if (!Array.isArray(spec.tabs)) errs.push('"tabs" trebuie să fie listă.');
    else spec.tabs.forEach(function (t, i) {
      var sid = t && (t.screen || t.id);
      if (!sid || !screens[sid]) errs.push('tabs[' + i + '] indică un ecran inexistent: ' + sid);
    });
  }
  if (spec.state !== undefined && (typeof spec.state !== 'object' || Array.isArray(spec.state))) errs.push('"state" trebuie să fie obiect.');
  if (spec.persist !== undefined && !Array.isArray(spec.persist)) errs.push('"persist" trebuie să fie listă de chei.');
  if (spec.script !== undefined && typeof spec.script !== 'string') errs.push('"script" trebuie să fie text JS.');
  if (typeof spec.script === 'string') { try { new Function(spec.script); } catch (e) { errs.push('Eroare de sintaxă în script: ' + e.message); } }
  if (spec.onLoad) __compileAction(String(spec.onLoad));
  // go('x') targets
  var all = JSON.stringify(spec);
  var re = /go\(\s*\\?["']([^"'\\]+)\\?["']\s*\)/g, m;
  while ((m = re.exec(all))) if (!screens[m[1]]) errs.push('go("' + m[1] + '") indică un ecran inexistent.');
  __af.errList.forEach(function (e) { if (errs.indexOf(e) < 0) errs.push(e); });
  return errs;
}
// Loads state defaults + script. Host calls this once, then renders.
function __boot(json, saved) {
  var spec = typeof json === 'string' ? JSON.parse(json) : json;
  var st = spec.state || {};
  state = JSON.parse(JSON.stringify(st));
  if (saved) for (var k in saved) { try { state[k] = JSON.parse(saved[k]); } catch (e) {} }
  if (typeof spec.script === 'string' && spec.script.length) {
    try { (0, eval)(spec.script); } catch (e) { __err('Eroare în script: ' + e.message); }
  }
  if (spec.onLoad) __runAction(__compileAction(String(spec.onLoad)), null, 0, null);
  return true;
}
function __persistJSON(keys) {
  var o = {};
  (keys || []).forEach(function (k) { try { o[k] = JSON.stringify(state[k] === undefined ? null : state[k]); } catch (e) {} });
  return o;
}
function __listItems(i, item, index) {
  var v = __evalExpr(i, item, index);
  if (!Array.isArray(v)) return { n: 0, sig: '[]' };
  var sig; try { sig = JSON.stringify(v); } catch (e) { sig = String(v.length); }
  return { n: v.length, sig: sig };
}
function __listItem(i, k, item, index) { var v = __evalExpr(i, item, index); return Array.isArray(v) ? v[k] : null; }
var size = {};
function __setPath(p, v) {
  var parts = String(p).split('.'), o = state;
  for (var i = 0; i < parts.length - 1; i++) {
    if (o[parts[i]] == null || typeof o[parts[i]] !== 'object') o[parts[i]] = {};
    o = o[parts[i]];
  }
  o[parts[parts.length - 1]] = v;
}
function __getPath(p) {
  var parts = String(p).split('.'), o = state;
  for (var i = 0; i < parts.length; i++) { if (o == null) return null; o = o[parts[i]]; }
  return o === undefined ? null : o;
}
// Headless check used by the AI repair loop: boot + evaluate every binding once.
function __dryRun(json) {
  var spec = typeof json === 'string' ? JSON.parse(json) : json;
  __boot(spec, null);
  (spec.screens || []).forEach(function (s) {
    if (s.title) { var t = __template(s.title); if (t) __evalExpr(__compileExpr(t), null, 0); }
    __dryNode(s.body, null, 0);
  });
  return __af.errList.slice();
}
function __dryNode(n, item, index) {
  if (!n || typeof n !== 'object') return;
  var t = __normType(n.type);
  Object.keys(n).forEach(function (k) {
    if (k === 'row' || k === 'children' || __ACTION_PROPS[k]) return;
    var v = n[k];
    if (t === 'list' && k === 'items') return;
    if (__EXPR_PROPS[k] && typeof v === 'string') __evalExpr(__compileExpr(v), item, index);
    else if (typeof v === 'string') { var tp = __template(v); if (tp) __evalExpr(__compileExpr(tp), item, index); }
  });
  if (t === 'list' && n.items) {
    var arr = __evalExpr(__compileExpr(String(n.items)), item, index);
    if (Array.isArray(arr)) { if (arr.length) __dryNode(n.row, arr[0], 0); }
    else if (arr != null) __err('"items" al listei nu e o listă: ' + n.items);
  }
  (n.children || []).forEach(function (c) { __dryNode(c, item, index); });
}
