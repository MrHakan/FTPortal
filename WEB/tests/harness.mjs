import { Script } from 'node:vm';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../portal.html', import.meta.url), 'utf8');
class Element {
  constructor(tag = 'div') {
    this.tag = tag; this.children = []; this.listeners = {}; this.attributes = {}; this.dataset = {};
    this.classes = new Set(); this.style = {}; this.value = ''; this.textContent = ''; this.disabled = false;
    this.classList = {
      add: key => this.classes.add(key), remove: key => this.classes.delete(key),
      contains: key => this.classes.has(key),
      toggle: (key, force) => (force === undefined ? !this.classes.has(key) : force) ? this.classes.add(key) : this.classes.delete(key)
    };
  }
  appendChild(child) {
    if (child.tag === 'fragment') child.children.forEach(node => this.appendChild(node));
    else { this.children.push(child); child.parent = this; }
    return child;
  }
  replaceChildren(...children) { this.children = []; children.forEach(child => this.appendChild(child)); }
  addEventListener(name, callback) { this.listeners[name] = callback; }
  setAttribute(key, value) { this.attributes[key] = value; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter(node => node !== this); }
  focus() {}
  select() {}
  click() { return this.listeners.click?.call(this, {}); }
  get childElementCount() { return this.children.length; }
  get firstChild() { return this.children[0]; }
}
export const flush = () => new Promise(resolve => setImmediate(resolve));
export const defaultInfo = () => ({ platform: 'Windows', alias: 'Bridge PC', maxUploadBytes: 1024,
  lobbyActive: true, peerAvailable: true, files: [{ id: 'abc123', name: '<test>.txt', size: 32 }],
  addresses: [{ url: 'http://192.168.1.5:8080/dashboard', kind: 'Wi-Fi' }] });
export function portal({ info = defaultInfo(), mode = '/dashboard', fetchImpl, responses = [] } = {}) {
  const elements = new Map(), requests = [], fetches = [], timers = new Map(), windowEvents = {}, documentEvents = {};
  let timerId = 0;
  const get = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
  for (const match of html.matchAll(/<[^>]+id="([^"]+)"[^>]*>/g)) {
    const node = get(match[1]), cls = match[0].match(/class="([^"]+)"/);
    if (cls) cls[1].split(' ').forEach(key => node.classes.add(key));
  }
  const tabs = ['all', 'available', 'sent'].map(value => { const tab = new Element('button'); tab.dataset.filter = value; return tab; });
  function QRCode(node, options) { node.appendChild({ value: options.text }); }
  QRCode.CorrectLevel = { M: 1 };
  class FormData { append(name, file) { this.file = file; } }
  class XHR {
    constructor() { this.upload = {}; }
    open(method, url) { this.method = method; this.url = url; }
    send(data) {
      this.file = data.file; requests.push(this);
      if (responses.length) setImmediate(() => this.respond(...responses.shift()));
    }
    respond(status = 200, response = { ok: true }) { this.status = status; this.responseText = typeof response === 'string' ? response : JSON.stringify(response); this.onload(); }
    abort() { this.onabort?.(); }
  }
  const document = {
    getElementById: get, createElement: tag => new Element(tag), createDocumentFragment: () => new Element('fragment'),
    createTextNode: text => ({ textContent: text }), querySelectorAll: () => tabs, body: new Element(), hidden: false,
    addEventListener: (name, fn) => documentEvents[name] = fn, execCommand: () => false
  };
  const window = { QRCode, addEventListener: (name, fn) => windowEvents[name] = fn };
  new Script(html.match(/<script>([\s\S]*?)<\/script>/)[1]).runInNewContext({
    document, window, QRCode, URL, location: { pathname: mode, origin: 'http://127.0.0.1:8080', hostname: '127.0.0.1' },
    localStorage: { getItem: () => null, setItem() {} }, navigator: {}, File, FormData, XMLHttpRequest: XHR, AbortController,
    fetch: async (...args) => { fetches.push(args); return fetchImpl ? fetchImpl(...args) : { ok: true, json: async () => structuredClone(info) }; },
    setTimeout: (fn, delay) => { const id = ++timerId; timers.set(id, { fn, delay }); return id; }, clearTimeout: id => timers.delete(id), console
  });
  const stage = files => { get('file').files = files; get('file').listeners.change.call(get('file')); };
  return { get, stage, document, tabs, windowEvents, documentEvents, requests, fetches, timers,
    refresh: () => get('refreshBtn').click(), send: () => get('upBtn').click(), cancel: () => get('cancelBtn').click() };
}
