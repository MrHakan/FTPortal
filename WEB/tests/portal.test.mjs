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


import { portal, defaultInfo, flush } from './harness.mjs';

test('classic dashboard safely renders shares, host and usable Invite/Lobby addresses', async () => {
  const ui = portal({ mode: '/lobby' }); await flush();
  assert.equal(ui.get('myNick').textContent, 'Bridge PC');
  assert.equal(ui.get('devices').childElementCount, 2);
  assert.equal(ui.get('transferBody').children[0].children[1].textContent, '<test>.txt');
  assert.equal(ui.get('lobbyQr').children[0].value, 'http://192.168.1.5:8080/dashboard');
  assert.equal(ui.get('connectionText').textContent, 'Connected to host');
  assert.equal(ui.get('hostDot').classes.has('offline'), false);
});

test('unchanged refresh keeps rendered rows and queue buttons rather than discarding focus', async () => {
  const ui = portal(); await flush(); ui.stage([new File(['a'], 'a.txt')]);
  const row = ui.get('transferBody').children[0], queueRow = ui.get('fileList').children[0];
  await ui.refresh();
  assert.equal(ui.get('transferBody').children[0], row);
  assert.equal(ui.get('fileList').children[0], queueRow);
});

test('large lists are paged and searches apply before rendering', async () => {
  const info = defaultInfo(); info.files = Array.from({ length: 251 }, (_, id) => ({ id: String(id), name: `file-${id}.txt`, size: 4 }));
  const ui = portal({ info }); await flush();
  assert.equal(ui.get('transferBody').childElementCount, 100);
  ui.get('moreBtn').click(); assert.equal(ui.get('transferBody').childElementCount, 200);
  ui.get('search').value = 'file-250'; ui.get('search').listeners.input();
  assert.equal(ui.get('transferBody').childElementCount, 1);
  assert.equal(ui.get('resultCount').textContent, '1 of 1 file(s)');
});

test('queue bounds, deduplication and oversize admission apply before network requests', async () => {
  const ui = portal(); await flush();
  const big = new File(['x'.repeat(1025)], 'big.txt'); ui.stage([big, big]);
  assert.equal(ui.get('fileList').childElementCount, 1); assert.equal(ui.get('upBtn').disabled, true);
  ui.stage(Array.from({ length: 220 }, (_, id) => new File(['x'], `small-${id}.txt`)));
  assert.equal(ui.get('fileList').childElementCount, 200); assert.equal(ui.requests.length, 0);
});

test('server confirmation releases successful File references and keeps only failed files for retry', async () => {
  const ui = portal({ responses: [[200, 'not JSON'], [200, { ok: true }]] }); await flush();
  const file = new File(['data'], 'hello.txt'); ui.stage([file]); await ui.send();
  assert.equal(ui.get('fileList').childElementCount, 1); assert.match(ui.get('upBtn').textContent, /retry/);
  await ui.send(); assert.equal(ui.get('fileList').childElementCount, 0);
  ui.tabs[2].click(); assert.equal(ui.get('transferBody').childElementCount, 1);
  assert.equal(ui.get('transferBody').children[0].children[1].textContent, 'hello.txt');
  ui.stage([file]); assert.equal(ui.get('fileList').childElementCount, 1, 'confirmed files can be selected again');
});

test('cancellation stops the batch, restores controls, and allows remaining files to retry', async () => {
  const ui = portal(); await flush(); ui.stage([new File(['a'], 'a.txt'), new File(['b'], 'b.txt')]);
  const sending = ui.send(); assert.equal(ui.requests.length, 1); assert.equal(ui.get('file').disabled, true);
  ui.cancel(); await sending;
  assert.equal(ui.requests.length, 1); assert.equal(ui.get('fileList').childElementCount, 2);
  assert.equal(ui.get('file').disabled, false); assert.equal(ui.get('upBtn').disabled, false);
  const retry = ui.send(); ui.requests[1].respond(); await flush(); ui.requests[2].respond(); await retry;
  assert.equal(ui.get('fileList').childElementCount, 0);
});

test('synchronous upload failures and idle timeouts settle the batch and release busy state', async () => {
  const ui = portal(); await flush(); ui.stage([new File(['a'], 'a.txt')]);
  const pending = ui.send();
  const idle = [...ui.timers.values()].find(timer => timer.delay === 60000); assert.ok(idle);
  idle.fn(); await pending;
  assert.equal(ui.get('file').disabled, false); assert.equal(ui.get('upBtn').disabled, false);
  assert.match(ui.get('fileList').children[0].children[3].title, /Check.*before retrying/);
});

test('overlapping refreshes are coalesced and offline recovery preserves staged files', async () => {
  let resolveFetch, online = false;
  const ui = portal({ fetchImpl: () => new Promise(resolve => { resolveFetch = resolve; }) });
  await ui.refresh(); ui.windowEvents.focus(); assert.equal(ui.fetches.length, 1);
  resolveFetch({ ok: false }); await flush();
  ui.stage([new File(['a'], 'a.txt')]); assert.equal(ui.get('upBtn').disabled, true);
  assert.equal(ui.get('hostDot').classes.has('offline'), true);
  const recovery = ui.refresh(); resolveFetch({ ok: true, json: async () => defaultInfo() }); await recovery;
  assert.equal(ui.get('upBtn').disabled, false); assert.equal(ui.get('fileList').childElementCount, 1);
  assert.equal(ui.get('hostDot').classes.has('offline'), false);
});

test('hidden tabs poll less often; invalid URLs are never inserted into QR codes', async () => {
  const info = defaultInfo(); info.addresses.unshift({ url: 'javascript:alert(1)', kind: 'fake' });
  const ui = portal({ info, mode: '/lobby' }); await flush();
  assert.equal(ui.get('bearers').childElementCount, 1);
  ui.document.hidden = true; ui.documentEvents.visibilitychange();
  assert.ok([...ui.timers.values()].some(timer => timer.delay === 15000));
  assert.equal(ui.get('lobbyQr').children[0].value, 'http://192.168.1.5:8080/dashboard');
});

test('zero-byte files may be uploaded and successful history stays bounded at 100 receipts', async () => {
  const responses = Array.from({ length: 102 }, () => [200, { ok: true }]);
  const ui = portal({ responses }); await flush();
  ui.stage(Array.from({ length: 102 }, (_, id) => new File([], `empty-${id}.txt`))); await ui.send();
  assert.equal(ui.get('fileList').childElementCount, 0); ui.tabs[2].click();
  assert.equal(ui.get('resultCount').textContent, '100 of 100 file(s)');
});
