// Captura los IDs de los Shorts que aparecen ORGANICAMENTE en el feed "For You"
// de tu cuenta de YouTube (youtube.com/shorts), usando tus cookies autenticadas.
// Escribe las URLs /shorts/<id> a un archivo que luego yt-dlp baja (tag [FEED]).
//
// Corre en el HOST (no en Docker): Playwright necesita navegador.
//   node capture-shorts-feed.mjs
// Env: HEADLESS=true|false  TARGET=25  MAX_SWIPES=60  OUT=<path>  COOKIES=<path>

import { createRequire } from 'module';
import { readFileSync, writeFileSync } from 'fs';
const require = createRequire('/Users/jlgarcia/WebstormProjects/IOGrid/IOGridUI/');
const { chromium } = require('playwright');

const COOKIES = process.env.COOKIES || '/Users/jlgarcia/youtube-complex/youtube/config/cookies.txt';
const OUT = process.env.OUT || '/Users/jlgarcia/youtube-complex/youtube/config/shorts-feed-ids.txt';
const TARGET = parseInt(process.env.TARGET || '25', 10);
const MAX_SWIPES = parseInt(process.env.MAX_SWIPES || '60', 10);
const HEADLESS = (process.env.HEADLESS || 'false') === 'true';

// Parse Netscape cookies.txt -> Playwright cookie objects
function parseCookies(path) {
  const out = [];
  for (const raw of readFileSync(path, 'utf8').split('\n')) {
    if (!raw || raw.startsWith('#')) continue;
    const p = raw.split('\t');
    if (p.length < 7) continue;
    const [domain, , cpath, secure, expiry, name, value] = p;
    const c = { name, value, domain, path: cpath || '/', secure: secure === 'TRUE', httpOnly: false, sameSite: 'None' };
    const exp = parseInt(expiry, 10);
    if (exp > 0) c.expires = exp;
    out.push(c);
  }
  return out;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rnd = (a, b) => a + Math.floor(Math.random() * (b - a));

(async () => {
  const cookies = parseCookies(COOKIES);
  console.log(`[capture] cargando ${cookies.length} cookies`);

  const browser = await chromium.launch({ headless: HEADLESS });
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  });
  await ctx.addCookies(cookies);
  const page = await ctx.newPage();

  const ids = new Set();
  const ID_RE = /"videoId":"([A-Za-z0-9_-]{11})"/g;

  // Intercepta las respuestas del feed de reels: de ahi salen los IDs organicos.
  page.on('response', async (res) => {
    const url = res.url();
    if (!/youtubei\/v1\/reel\/(reel_watch_sequence|reel_item_watch)/.test(url)) return;
    try {
      const txt = await res.text();
      let m;
      while ((m = ID_RE.exec(txt)) !== null) ids.add(m[1]);
    } catch {}
  });

  console.log('[capture] abriendo youtube.com/shorts ...');
  await page.goto('https://www.youtube.com/shorts', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await sleep(4000);

  // Confirma login
  const loggedIn = await page.evaluate(() => {
    return !!(document.cookie.includes('SID') || document.querySelector('img#avatar-btn, #avatar-btn'));
  }).catch(() => false);
  console.log(`[capture] login detectado (heuristica): ${loggedIn}`);

  // Captura el ID actual del DOM/URL tambien (fallback)
  const grabDom = async () => {
    const id = await page.evaluate(() => {
      const m = location.pathname.match(/\/shorts\/([A-Za-z0-9_-]{11})/);
      return m ? m[1] : null;
    }).catch(() => null);
    if (id) ids.add(id);
  };
  await grabDom();

  let swipes = 0;
  let lastCount = 0;
  let stale = 0;
  while (ids.size < TARGET && swipes < MAX_SWIPES) {
    await page.keyboard.press('ArrowDown');
    swipes++;
    await sleep(rnd(900, 1800)); // delays humanos para no gatillar bot-detection
    await grabDom();
    if (ids.size === lastCount) {
      stale++;
      if (stale >= 8) { console.log('[capture] feed sin IDs nuevos, corto'); break; }
    } else {
      stale = 0;
      lastCount = ids.size;
    }
    if (swipes % 5 === 0) console.log(`[capture] swipes=${swipes} ids=${ids.size}`);
  }

  await browser.close();

  const list = [...ids];
  const urls = list.map((id) => `https://www.youtube.com/shorts/${id}`);
  writeFileSync(OUT, urls.join('\n') + (urls.length ? '\n' : ''));
  console.log(`[capture] OK: ${list.length} IDs organicos -> ${OUT}`);
  console.log(list.slice(0, 10).join(' '));
})().catch((e) => {
  console.error('[capture] ERROR:', e.message);
  process.exit(1);
});
