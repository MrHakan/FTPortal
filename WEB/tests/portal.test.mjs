import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { Script } from 'node:vm';

const root = resolve(import.meta.dirname, '../..');
const html = readFileSync(resolve(root, 'WEB/portal.html'), 'utf8');
const windows = readFileSync(resolve(root, 'WINDOWS/PortalServer.cs'), 'utf8');
const android = readFileSync(resolve(root, 'ANDROID/app/src/main/java/com/mrhakan/ftportal/PortalServer.kt'), 'utf8');
const ios = readFileSync(resolve(root, 'IOS/Sources/PortalServer.swift'), 'utf8');

test('shared dashboard is offline, parses, and has no hard-coded passwords or external resources', () => {
  const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];
  assert.ok(script, 'inline script missing');
  assert.doesNotThrow(() => new Script(script));
  assert.doesNotMatch(html, /(?:<script[^>]+src=|<link[^>]+href=|https?:\/\/[^\s'"<]+)/i);
  assert.doesNotMatch(html, /hako123|password.*default/i);
  assert.match(html, /ONE-SHOT/);
  assert.match(html, /native app/);
});

test('each native host exposes the same routes without removing the original fallback', () => {
  for (const [name, source] of Object.entries({ windows, android, ios })) {
    for (const path of ['/dashboard', '/lobby', '/api/portal', '/upload', '/api/state']) {
      assert.ok(source.includes(path), `${name} missing ${path}`);
    }
    assert.match(source, /ftportal|PeerProtocol/i);
  }
  assert.match(windows, /GetManifestResourceStream/);
  assert.match(android, /getOrElse \{ html\(\) \}/);
  assert.match(ios, /Bundle\.main\.url/);
});

test('iOS bundled page exactly matches the shared source', () => {
  assert.equal(readFileSync(resolve(root, 'IOS/Resources/portal.html'), 'utf8'), html);
});
