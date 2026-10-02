// Focused browser regression checks. Serve a fresh tools/build_web.sh output
// with tools/serve.sh, then run with Playwright and Chrome available.
const {chromium} = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const base = process.env.AWM_TEST_URL || 'http://127.0.0.1:8080';
const output = path.resolve(__dirname, '../build/test-output');
fs.mkdirSync(output, {recursive: true});
const classes = ['Archer', 'Warrior', 'Mage'];

// Pick visible chest positions in the terrace's world space. Use CSS pixels
// throughout so the same actual model is hit on standard and Retina displays.
// Scene constants live in scene/heroselectstage.nim; UI labels in heroselect.nim.
function projectHeroPoint(viewport, index, height) {
  const aspect = viewport.width / viewport.height;
  const distance = Math.max(1, 1.35 / aspect);
  const eye = [0, 1.7 + 2.7 * distance, 13.8 * distance];
  const length = Math.hypot(2.7, 13.8);
  const forward = [0, -2.7 / length, -13.8 / length];
  const up = [0, 13.8 / length, -2.7 / length];
  const relative = [(index - 1) * 4.2, 0.24 + height - eye[1], -eye[2]];
  const depth = relative[1] * forward[1] + relative[2] * forward[2];
  const vertical = relative[1] * up[1] + relative[2] * up[2];
  const focal = Math.tan(42 * Math.PI / 360);
  return {
    x: (1 + relative[0] / (depth * focal * aspect)) * viewport.width / 2,
    y: (1 - vertical / (depth * focal)) * viewport.height / 2,
  };
}
function choicePoint(viewport, index, target = 'hero') {
  if (target === 'hero') return projectHeroPoint(viewport, index, 1.95 * 1.5 * 0.5);
  const portrait = viewport.width < viewport.height * 0.9;
  const scale = Math.min(1, viewport.width / (portrait ? 1000 : 2400), viewport.height / 1500);
  const width = viewport.width / scale;
  const height = viewport.height / scale;
  const feet = projectHeroPoint(viewport, index, 0);
  const panelWidth = Math.min(540, (width - 112) / 3);
  const panelHeight = portrait ? 300 : 258;
  const center = portrait ? width * (index + 0.5) / 3 : feet.x / scale;
  const left = Math.max(20, Math.min(width - panelWidth - 20, center - panelWidth / 2));
  const top = Math.min(feet.y / scale + 56, height - panelHeight - 104);
  return {x: (left + panelWidth / 2) * scale,
    y: (top + panelHeight - (portrait ? 66 : 62)) * scale};
}

(async () => {
  const browser = await chromium.launch({
    ...(process.env.CHROME_PATH ? {executablePath: process.env.CHROME_PATH} : {channel: 'chrome'}),
    headless: true,
    args: ['--enable-unsafe-swiftshader'],
  });
  const errors = [];
  const status = page => page.locator('#game-status').textContent();
  const screenshot = (page, name) => page.screenshot({path: path.join(output, `${name}.png`), animations: 'disabled'});
  async function createPage(viewport, deviceScaleFactor = 1) {
    const page = await browser.newPage({viewport, deviceScaleFactor});
    page.on('pageerror', error => errors.push(error.stack || error.message));
    page.on('console', message => {
      if (message.type() === 'error') errors.push(message.text());
    });
    return page;
  }
  async function waitStatus(page, pattern) {
    await page.waitForFunction(source => new RegExp(source).test(
      document.querySelector('#game-status').textContent), pattern.source, {timeout: 90000});
  }
  async function renderedFrames(page) {
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() =>
      requestAnimationFrame(() => requestAnimationFrame(resolve)))));
  }
  async function loadingScreen(viewport, name) {
    const page = await createPage(viewport);
    // Exercise the shell while the game is not running, as on a slow download.
    await page.route('**/awm.js', route => route.fulfill({contentType: 'application/javascript', body: ''}));
    await page.goto(`${base}/awm.html`, {waitUntil: 'load'});
    await page.evaluate(() => document.fonts.ready);
    assert.equal(await page.locator('#loading').isVisible(), true);
    assert.match(await page.locator('.game-name').textContent(), /Archers.*Warriors.*Mages/);
    assert.equal(await page.locator('#loading canvas').count(), 0);
    const artwork = await page.locator('.loading-background, .game-logo').evaluateAll(images =>
      images.map(image => ({src: image.getAttribute('src'), valid: image.complete && image.naturalWidth > 0})));
    assert.equal(artwork.length, 2, 'the loader must show its flat background and AWM logo');
    assert.ok(artwork.every(image => image.valid), 'loading background and logo must decode');
    assert.equal(await page.locator('#loading-note').isVisible(), false);
    assert.doesNotMatch(await page.locator('#loading').textContent(), /Your battle is taking shape/);
    assert.equal(await page.locator('#loading').evaluate(element => element.scrollWidth <= element.clientWidth), true,
      'loading screen must not overflow horizontally');
    await page.evaluate(() => Module.setStatus('Downloading data... (500/1000)'));
    assert.equal(await page.locator('#progress').getAttribute('aria-valuenow'), '50');
    assert.equal(await page.locator('#progress-value').textContent(), '50%');
    await screenshot(page, name);
    await page.evaluate(() => Module.monitorRunDependencies(0));
    assert.equal(await page.locator('#progress').getAttribute('aria-valuenow'), null,
      'preparation must not show an invented percentage');
    // Runtime initialization precedes expensive atlas/scene initialization.
    // Keep the artwork visible until the game publishes its first frame.
    await page.evaluate(() => Module.onRuntimeInitialized());
    await page.waitForTimeout(400);
    assert.equal(await page.locator('#loading').isVisible(), true);
    assert.equal(await page.locator('#progress').getAttribute('aria-valuenow'), null);
    await page.evaluate(() => { document.querySelector('#game-status').textContent = 'Human player. Choose your class.'; });
    await page.waitForFunction(() => document.querySelector('#loading').classList.contains('ready'));
    assert.equal(await page.locator('#progress').getAttribute('aria-valuenow'), '100');
    // An abort during the ready transition must remain visible after its timer.
    await page.evaluate(() => Module.onAbort('Regression check'));
    await page.waitForTimeout(450);
    assert.equal(await page.locator('#loading').isVisible(), true);
    assert.equal(await page.locator('#retry').isVisible(), true);
    assert.equal(await page.locator('#error-details').textContent(), 'Regression check');
    await page.close();
  }
  async function humanChoice({name, index, target = 'hero', players = 2,
      viewport = {width: 1440, height: 900}, density = 1, outside = false, animate = false}) {
    const page = await createPage(viewport, density);
    await page.goto(`${base}/awm.html?human=1&players=${players}&seed=42`, {waitUntil: 'domcontentloaded'});
    await waitStatus(page, /Choose your (class|hero)/);
    await page.locator('#loading').waitFor({state: 'hidden', timeout: 30000});
    assert.match(await status(page), /Human player/);
    if (outside) {
      await page.mouse.click(8, viewport.height / 2);
      await renderedFrames(page);
      assert.match(await status(page), /Choose your (class|hero)/, 'clicks outside heroes and buttons must not start a game');
    }
    await screenshot(page, name);
    if (animate) {
      const hero = choicePoint(viewport, index);
      const clip = {x: hero.x - 28, y: hero.y - 48, width: 56, height: 96};
      const idleBefore = await page.screenshot({clip});
      await page.waitForTimeout(450);
      const idleAfter = await page.screenshot({clip});
      assert.equal(idleBefore.equals(idleAfter), false, 'the visible hero must animate while awaiting a choice');
      await screenshot(page, `${name}-animated`);
    }
    if (target === 'keyboard') {
      await page.keyboard.press(String(index + 1));
    } else {
      const point = choicePoint(viewport, index, target);
      await page.mouse.click(point.x, point.y);
    }
    await waitStatus(page, /Turn \d+\./);
    await renderedFrames(page);
    const summary = await status(page);
    assert.match(summary, new RegExp(`Player 1 ${classes[index]}: life`), `${target} chooses ${classes[index]}`);
    assert.match(summary, /Human player/);
    if (players > 2) assert.match(summary, new RegExp(`Multiplayer match: ${players} players\\.`));
    assert.doesNotMatch(summary, /Choose your (class|hero)/);
    console.log(`PASS: ${name} (${target} → ${classes[index]})`);
    await page.close();
  }
  async function botChoice(players) {
    const viewport = {width: 1024, height: 768};
    const page = await createPage(viewport);
    await page.goto(`${base}/awm.html?players=${players}&seed=42`, {waitUntil: 'domcontentloaded'});
    await waitStatus(page, /Bots are choosing/);
    await page.locator('#loading').waitFor({state: 'hidden', timeout: 30000});
    const hero = choicePoint(viewport, 0);
    const button = choicePoint(viewport, 2, 'button');
    await page.mouse.click(hero.x, hero.y);
    await page.mouse.click(button.x, button.y);
    await page.keyboard.press('2');
    await renderedFrames(page);
    assert.match(await status(page), /Bots are choosing/, 'bot preview must ignore hero, button and keyboard input');
    await waitStatus(page, /Turn \d+\./);
    assert.match(await status(page), /Bot match/);
    assert.doesNotMatch(await status(page), /Human player/);
    console.log(`PASS: ${players}-player bot selection remains automatic`);
    await page.close();
  }
  try {
    await loadingScreen({width: 1440, height: 900}, 'loading-desktop');
    await loadingScreen({width: 390, height: 844}, 'loading-mobile');
    await humanChoice({name: 'hero-select-desktop', index: 0, outside: true, animate: true});
    await humanChoice({name: 'hero-select-portrait', index: 1, viewport: {width: 390, height: 844}});
    await humanChoice({name: 'hero-select-retina', index: 2, viewport: {width: 1280, height: 800}, density: 2});
    await humanChoice({name: 'hero-select-button', index: 1, target: 'button', viewport: {width: 1024, height: 768}});
    await humanChoice({name: 'hero-select-multiplayer-hero', index: 0, players: 4});
    await humanChoice({name: 'hero-select-multiplayer-archer-button', index: 0, players: 4, target: 'button'});
    await humanChoice({name: 'hero-select-multiplayer-button', index: 2, players: 4,
      target: 'button', viewport: {width: 390, height: 844}, density: 2});
    await humanChoice({name: 'hero-select-keyboard', index: 2, target: 'keyboard'});
    await botChoice(2);
    await botChoice(4);
    assert.deepEqual(errors, [], 'browser must not report JavaScript, Wasm or resource errors');
    console.log('PASS: flat loading background/logo/progress/readiness/error recovery; all classes; animated hero and button clicks; duel/multiplayer; portrait/Retina; keyboard and bot isolation.');
  } catch (error) {
    for (const [index, page] of browser.contexts().flatMap(context => context.pages()).entries()) {
      console.error('Page state:', await status(page).catch(() => 'unavailable'));
      await screenshot(page, `hero-select-failure-${index}`).catch(() => {});
    }
    console.error('Browser errors:', errors);
    throw error;
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
