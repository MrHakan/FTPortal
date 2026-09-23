import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { Script } from 'node:vm';

const root = resolve(import.meta.dirname, '../..');
const html = readFileSync(resolve(root, 'WEB/portal.html'), 'utf8');
const qr = readFileSync(resolve(root, 'WEB/qr.js'), 'utf8');
const windows = readFileSync(resolve(root, 'WINDOWS/PortalServer.cs'), 'utf8');
const android = readFileSync(resolve(root, 'ANDROID/app/src/main/java/com/mrhakan/ftportal/PortalServer.kt'), 'utf8');
const ios = readFileSync(resolve(root, 'IOS/Sources/PortalServer.swift'), 'utf8');

test('shared dashboard is offline, parses, and has no hard-coded passwords or external resources', () => {
  const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
  assert.ok(script, 'inline script missing');
  assert.doesNotThrow(() => new Script(script));
  assert.doesNotMatch(html, /<(?:script|link|img)[^>]+(?:src|href)=["']https?:/i);
  assert.match(html, /<script src="\/qr\.js"><\/script>/);
  assert.doesNotThrow(() => new Script(qr));
  assert.doesNotMatch(html, /hako123|password.*default/i);
  assert.match(html, /one-shot/i);
  assert.match(html, /native app/);
  for (const id of ['inviteBtn', 'inviteQr', 'lobbyQr', 'devices', 'fileList', 'transferBody', 'bearers']) {
    assert.match(html, new RegExp('id="' + id + '"'));
  }
  assert.doesNotMatch(html, /Target: Everyone|Sign Out|select a folder|Download Selected/i);
});

test('each native host exposes the same routes without removing the original fallback', () => {
  for (const [name, source] of Object.entries({ windows, android, ios })) {
    for (const path of ['/dashboard', '/lobby', '/api/portal', '/upload', '/api/state', '/qr.js']) {
      assert.ok(source.includes(path), `${name} missing ${path}`);
    }
    assert.match(source, /ftportal|PeerProtocol/i);
  }
  assert.match(windows, /GetManifestResourceStream/);
  assert.match(android, /assetText\("portal\.html"\) \?: html\(\)/);
  assert.match(ios, /Bundle\.main\.url/);
});

test('iOS bundled page exactly matches the shared source', () => {
  assert.equal(readFileSync(resolve(root, 'IOS/Resources/portal.html'), 'utf8'), html);
  assert.equal(readFileSync(resolve(root, 'IOS/Resources/qr.js'), 'utf8'), qr);
  assert.equal(readFileSync(resolve(root, 'IOS/Resources/qr.LICENSE'), 'utf8'), readFileSync(resolve(root, 'WEB/qr.LICENSE'), 'utf8'));
});

test('classic dashboard renders actual shares, browser host, lobby QR and active addresses', async () => {
  class Element {
    constructor() {
      this.children = [];
      this.listeners = {};
      this.dataset = {};
      this.classes = new Set();
      this.classList = {
        add: (key) => this.classes.add(key),
        contains: (key) => this.classes.has(key),
        toggle: (key, force) => {
          if (force === undefined ? !this.classes.has(key) : force) this.classes.add(key);
          else this.classes.delete(key);
        }
      };
    }
    appendChild(child) { this.children.push(child); return child; }
    replaceChildren(...children) { this.children = children; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    setAttribute() {}
    remove() {}
    get childElementCount() { return this.children.length; }
  }
  const elements = new Map();
  const get = (id) => {
    if (!elements.has(id)) elements.set(id, new Element());
    return elements.get(id);
  };
  const tabs = ['all', 'available', 'sent'].map((value) => {
    const tab = new Element();
    tab.dataset.filter = value;
    return tab;
  });
  const info = { platform: 'Windows', alias: 'Bridge PC', maxUploadBytes: 1024,
    lobbyActive: true, files: [{ id: 'abc123', name: '<test>.txt', size: 32 }],
    addresses: [{ url: 'http://192.168.1.5:8080/dashboard', kind: 'Wi-Fi' }] };
  function QRCode(node, options) { node.appendChild({ value: options.text }); }
  QRCode.CorrectLevel = { M: 1 };
  const document = {
    getElementById: get,
    createElement: () => new Element(),
    createTextNode: (text) => ({ textContent: text }),
    querySelectorAll: () => tabs,
    body: new Element(),
    hidden: false
  };
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  new Script(script).runInNewContext({ document, URL, location: { pathname: '/dashboard', origin: 'http://127.0.0.1:8080', hostname: '127.0.0.1' },
    window: { QRCode, localStorage: { getItem: () => null }, addEventListener() {} }, QRCode,
    fetch: async () => ({ ok: true, json: async () => info }), setInterval() {}, setTimeout() {},
    navigator: {}, Notification: undefined, console });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(get('myNick').textContent, 'Bridge PC');
  assert.equal(get('devices').childElementCount, 2);
  assert.equal(get('transferBody').childElementCount, 1);
  assert.equal(get('transferBody').children[0].children[1].textContent, '<test>.txt');
  assert.equal(get('bearers').childElementCount, 1);
  assert.equal(get('lobbyQr').children[0].value, 'http://192.168.1.5:8080/dashboard');
  get('inviteBtn').listeners.click.call(get('inviteBtn'));
  assert.equal(get('inviteQr').children[0].value, 'http://192.168.1.5:8080/dashboard');
});
