import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFileSync, mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
const { chromium } = createRequire(import.meta.url)('playwright');
const pageHtml = readFileSync(new URL('../portal.html', import.meta.url));
const qr = readFileSync(new URL('../qr.js', import.meta.url));
let slow = false, uploads = 0;
const info = { platform: 'Windows', alias: 'Bridge PC', maxUploadBytes: 1024, peerAvailable: true, lobbyActive: true,
  files: [{ id: 'abc123', name: '<script>alert("test")</script>.txt', size: 16 }],
  addresses: [{ url: 'http://192.168.7.1:8080/dashboard', kind: 'Wi-Fi' }, { url: 'http://192.168.137.1:8080/dashboard', kind: 'Hotspot' }] };
const server = createServer((req, res) => {
  res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'");
  if (req.url === '/qr.js') { res.setHeader('Content-Type', 'application/javascript'); res.end(qr); }
  else if (req.url === '/api/portal') { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(info)); }
  else if (req.url === '/upload') {
    uploads++; req.resume(); req.on('end', () => {
      setTimeout(() => { if (!res.destroyed) { res.setHeader('Content-Type', 'application/json'); res.end('{"ok":true}'); } }, slow ? 1500 : 0);
    });
  } else { res.setHeader('Content-Type', 'text/html'); res.end(pageHtml); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await chromium.launch({ executablePath: process.env.FTPORTAL_CHROMIUM || undefined, headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1366, height: 900 } });
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin); await page.locator('#connectionText').filter({ hasText: 'Connected to host' }).waitFor();
  assert.equal(await page.locator('#transferBody script').count(), 0);
  assert.equal(await page.locator('#transferBody .td-nm').textContent(), info.files[0].name);
  await page.locator('#inviteBtn').click(); await page.locator('#inviteQr canvas').waitFor({ state: 'attached' });
  await page.locator('#file').setInputFiles([{ name: 'hello.txt', mimeType: 'text/plain', buffer: Buffer.from('hello') }, { name: 'empty.txt', mimeType: 'text/plain', buffer: Buffer.alloc(0) }]);
  await page.locator('#upBtn').click();
  await page.locator('#upStats').filter({ hasText: '2 / 2 received by host' }).waitFor();
  assert.equal(uploads, 2); assert.equal(await page.locator('#fileList .fileitem').count(), 0);
  await page.locator('[data-filter="sent"]').click(); assert.equal(await page.locator('#transferBody tr').count(), 2);
  await page.locator('#search').fill('empty'); assert.equal(await page.locator('#transferBody tr').count(), 1);
  slow = true;
  await page.locator('#file').setInputFiles([{ name: 'cancel.txt', mimeType: 'text/plain', buffer: Buffer.from('cancel') }, { name: 'later.txt', mimeType: 'text/plain', buffer: Buffer.from('later') }]);
  await page.locator('#upBtn').click(); await page.locator('#cancelBtn').click();
  await page.locator('#upStats').filter({ hasText: 'queue stopped' }).waitFor();
  assert.equal(await page.locator('#fileList .fileitem').count(), 2);
  assert.equal(await page.locator('#upBtn').isEnabled(), true);
  slow = false;
  if (process.env.FTPORTAL_SCREENSHOT_DIR) {
    mkdirSync(process.env.FTPORTAL_SCREENSHOT_DIR, { recursive: true });
    await page.evaluate(() => { document.activeElement.blur(); window.scrollTo(0, 0); });
    await page.screenshot({ path: join(process.env.FTPORTAL_SCREENSHOT_DIR, 'dashboard-desktop.png'), fullPage: true });
  }
  await page.goto(origin + '/lobby'); await page.locator('#lobbyQr canvas').waitFor({ state: 'attached' });
  await page.locator('#addressChoice').selectOption(info.addresses[1].url);
  assert.equal(await page.locator('#lobbyUrl').textContent(), info.addresses[1].url);
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, 'lobby overflows mobile viewport');
  if (process.env.FTPORTAL_SCREENSHOT_DIR) await page.screenshot({ path: join(process.env.FTPORTAL_SCREENSHOT_DIR, 'lobby-mobile.png'), fullPage: true });
  await page.goto(origin); await page.locator('#connectionText').filter({ hasText: 'Connected to host' }).waitFor();
  await page.locator('#file').setInputFiles({ name: 'very-long-filename-'.repeat(8) + '.txt', mimeType: 'text/plain', buffer: Buffer.from('x') });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, 'dashboard overflows mobile viewport');
  // Keyboard users can invoke the file selector without a pointer.
  const chooser = page.waitForEvent('filechooser'); await page.locator('#drop').focus(); await page.keyboard.press('Enter'); await chooser;
  assert.equal(await page.locator('#transferBody .dl').isVisible(), true, 'mobile download action must stay visible');
  if (process.env.FTPORTAL_SCREENSHOT_DIR) {
    await page.evaluate(() => { document.activeElement.blur(); window.scrollTo(0, 0); });
    await page.screenshot({ path: join(process.env.FTPORTAL_SCREENSHOT_DIR, 'dashboard-mobile.png'), fullPage: true });
  }
  assert.deepEqual(errors, []);
  console.log('Browser smoke passed: desktop/mobile layout, actual QR under CSP, uploads, cancellation, search, address selection and keyboard file picker.');
} finally {
  await browser?.close(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
}
