#!/usr/bin/env bash
# Bing organic traffic – randomly rotates multiple iPhone / iOS devices
# Keywords + target domain come from GitHub Actions env (TARGET_DOMAIN, SEARCH_KEYWORDS)
# Spoofs iPhone User-Agent via CDP (runs on Android emulator)
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"

CHROME_PKG="com.android.chrome"
HAVE_ROOT=0

log() { printf '[capture] %s\n' "$*"; }

# ---- keywords / domain from GitHub Actions inputs (env) ----
RESULT_HOST="${TARGET_DOMAIN:-gardengar.com}"
RESULT_HOST="${RESULT_HOST#www.}"
RESULT_HOST="${RESULT_HOST#https://}"
RESULT_HOST="${RESULT_HOST#http://}"
RESULT_HOST="${RESULT_HOST%%/*}"

RAW_KEYWORDS="${SEARCH_KEYWORDS:-gardengar.com}"
KEYWORDS_FILE="$(mktemp)"
printf '%s\n' "$RAW_KEYWORDS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' > "$KEYWORDS_FILE" || true
if [[ ! -s "$KEYWORDS_FILE" ]]; then
  echo "gardengar.com" > "$KEYWORDS_FILE"
fi
mapfile -t KW_ARR < "$KEYWORDS_FILE"
rm -f "$KEYWORDS_FILE"

PICKED_KEYWORD="${KW_ARR[RANDOM % ${#KW_ARR[@]}]}"
log "Target domain: $RESULT_HOST"
log "Keyword pool (${#KW_ARR[@]}): ${KW_ARR[*]}"
log "Picked keyword for this run: $PICKED_KEYWORD"

ENCODED_KEYWORD="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PICKED_KEYWORD")"
SEARCH_URL="https://www.bing.com/search?q=${ENCODED_KEYWORD}"
TARGET_URL="https://www.bing.com"
RESULT_TEXT="$PICKED_KEYWORD"
export RESULT_HOST RESULT_TEXT SEARCH_URL TARGET_URL

adb_sh() { adb shell "$@" | tr -d '\r'; }

wait_for_boot() {
  adb wait-for-device
  local i=0
  while (( i < 180 )); do
    [[ "$(adb_sh getprop sys.boot_completed 2>/dev/null || true)" == "1" ]] && { sleep 6; return 0; }
    sleep 2; i=$((i+1))
  done
  log "timed out waiting for boot"; return 1
}

uid_is_root() { [[ "$(adb_sh id -u 2>/dev/null || true)" == "0" ]]; }

ensure_root() {
  local i out
  for i in 1 2 3 4 5 6; do
    uid_is_root && { log "adb shell is root (uid=0)"; return 0; }
    out="$(adb root 2>&1 || true)"; log "adb root (${i}): ${out}"
    sleep 3; adb wait-for-device
  done
  uid_is_root && { log "adb shell is root (uid=0)"; return 0; }
  log "no root"; return 1
}

pick_iphone_profile() {
  local profiles=(
    "iPhone15,2|iPhone 14 Pro|390x844|3|17_0"
    "iPhone15,3|iPhone 14 Pro Max|430x932|3|17_0"
    "iPhone14,5|iPhone 13|390x844|3|16_6"
    "iPhone14,2|iPhone 13 Pro|390x844|3|16_6"
    "iPhone13,2|iPhone 12|390x844|3|16_5"
    "iPhone16,1|iPhone 15 Pro|393x852|3|17_1"
    "iPhone16,2|iPhone 15 Pro Max|430x932|3|17_1"
    "iPhone15,4|iPhone 15|393x852|3|17_0"
    "iPhone14,7|iPhone 14|390x844|3|16_6"
    "iPhone12,1|iPhone 11|414x896|2|16_5"
  )
  local choice="${profiles[RANDOM % ${#profiles[@]}]}"
  IFS='|' read -r IPHONE_MODEL IPHONE_NAME VIEWPORT DPR IOS_VER <<< "$choice"
  IPHONE_UA="Mozilla/5.0 (iPhone; CPU iPhone OS ${IOS_VER//_/_} like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  log "Selected iPhone: $IPHONE_NAME ($IPHONE_MODEL)  iOS $IOS_VER  viewport $VIEWPORT"
}

dump_identity() {
  {
    echo "=== shell ==="; adb_sh id || true
    echo; echo "=== base emulator identity ==="
    for key in ro.product.brand ro.product.manufacturer ro.product.model \
      ro.build.version.release ro.build.version.sdk; do
      printf '%s=%s\n' "$key" "$(adb_sh getprop "$key")"
    done
    echo; echo "=== iPhone spoof (applied via CDP) ==="
    echo "model=$IPHONE_MODEL"
    echo "name=$IPHONE_NAME"
    echo "ua=$IPHONE_UA"
    echo "viewport=$VIEWPORT"
    echo "dpr=$DPR"
    echo "ios=$IOS_VER"
    echo "keyword=$PICKED_KEYWORD"
    echo "domain=$RESULT_HOST"
  } | tee "$ARTIFACTS/identity.txt"
}

skip_chrome_welcome() {
  local cmdline='chrome --disable-fre --no-first-run --no-default-browser-check --disable-search-engine-choice-screen --disable-features=TranslateUI,ChromeWhatsNew,PrivacySandboxSettings4,InterestFeedContentSuggestions'
  local tmp; tmp="$(mktemp)"; printf '%s\n' "$cmdline" > "$tmp"
  adb shell am set-debug-app --persistent "$CHROME_PKG" >/dev/null || true
  adb push "$tmp" /data/local/tmp/chrome-command-line >/dev/null
  adb_sh chmod 644 /data/local/tmp/chrome-command-line || true
  [[ "$HAVE_ROOT" == "1" ]] && { adb push "$tmp" /data/local/chrome-command-line >/dev/null || true; }
  rm -f "$tmp"
  adb shell pm grant "$CHROME_PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  adb shell am force-stop "$CHROME_PKG" >/dev/null 2>&1 || true
  log "Chrome first-run flags written"
}

dismiss_chrome_sheets() {
  python3 - <<'PY'
import re, subprocess, time
EXACT = {"use without an account","no thanks","no, thanks","don't allow","not now","skip","got it","accept & continue","accept and continue","no thanks, i'll stay signed out","reject all","accept all","i agree","dismiss"}
def dump():
    subprocess.run(["adb","shell","uiautomator","dump","/sdcard/uidump.xml"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=False)
    p=subprocess.run(["adb","exec-out","cat","/sdcard/uidump.xml"],capture_output=True,check=False)
    return p.stdout.decode("utf-8","replace")
def nodes(xml):
    for m in re.finditer(r"<node\s+([^>]+)/?>", xml):
        a=dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        mm=re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", a.get("bounds",""))
        if not mm: continue
        x1,y1,x2,y2=map(int,mm.groups())
        yield (a.get("text","").strip().lower(),a.get("content-desc","").strip().lower(),(x1+x2)//2,(y1+y2)//2)
tapped=0
for _ in range(6):
    found=False
    for text,desc,x,y in nodes(dump()):
        if text in EXACT or desc in EXACT:
            subprocess.run(["adb","shell","input","tap",str(x),str(y)],check=False)
            tapped+=1; found=True; time.sleep(1.2); break
    if not found: break
print(f"dismissed {tapped} sheets",flush=True)
PY
}

resolve_chrome() {
  for pkg in com.android.chrome com.chrome.beta com.chrome.dev org.chromium.chrome; do
    if adb_sh pm path "$pkg" 2>/dev/null | grep -q "package:"; then
      CHROME_PKG="$pkg"; log "using browser package ${CHROME_PKG}"; return 0
    fi
  done
  log "Chrome not installed"; return 1
}

open_url() {
  adb shell am force-stop "$CHROME_PKG" >/dev/null 2>&1 || true
  sleep 1.5
  adb shell am start -p "$CHROME_PKG" -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$1" -f 0x10000000 >/dev/null
  log "opened $1"; sleep 5
}

wait_for_devtools() {
  local max="${1:-30}" i=0
  adb forward --remove tcp:9222 >/dev/null 2>&1 || true
  adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true
  while (( i < max )); do
    if curl -s --max-time 3 http://127.0.0.1:9222/json >/dev/null 2>&1; then
      local count
      count=$(curl -s --max-time 3 http://127.0.0.1:9222/json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([t for t in d if t.get('type')=='page']))" 2>/dev/null || echo 0)
      if [[ "$count" -gt 0 ]]; then
        log "DevTools ready (${count} tab(s))"
        return 0
      fi
    fi
    sleep 1.5
    i=$((i+1))
    if (( i % 5 == 0 )); then
      log "DevTools not ready yet (attempt $i/$max) – re-forwarding"
      adb forward --remove tcp:9222 >/dev/null 2>&1 || true
      adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true
    fi
  done
  log "DevTools wait timed out after ${max} attempts"
  return 1
}

screenshot() {
  adb exec-out screencap -p > "${ARTIFACTS}/$1"
  log "wrote ${ARTIFACTS}/$1"
}

settle_device() {
  adb shell svc power stayon true >/dev/null || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null || true
  adb shell locksettings set-disabled true >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb_sh wm size 1080x2340 || true
  adb_sh wm density 420 || true
}

do_organic_and_engage() {
  python3 -m pip install -q websocket-client --break-system-packages >/dev/null 2>&1 \
    || python3 -m pip install -q websocket-client >/dev/null 2>&1 || true

  adb forward --remove tcp:9222 >/dev/null 2>&1 || true
  adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true

  export IPHONE_UA IPHONE_NAME
  RESULT_HOST="$RESULT_HOST" RESULT_TEXT="$RESULT_TEXT" ARTIFACTS="$ARTIFACTS" \
  IPHONE_UA="$IPHONE_UA" IPHONE_NAME="$IPHONE_NAME" python3 - <<'PY'
import json, os, sys, time, random, urllib.request, subprocess
import websocket

HOST = os.environ["RESULT_HOST"].strip().lower()
TARGET = os.environ["RESULT_TEXT"].strip().lower()
ARTIFACTS = os.environ["ARTIFACTS"]
IPHONE_UA = os.environ.get("IPHONE_UA", "")
IPHONE_NAME = os.environ.get("IPHONE_NAME", "iPhone")

NUM_PAGES = random.randint(4, 6)
MIN_DWELL, MAX_DWELL = 55, 110

def get_tabs():
    with urllib.request.urlopen("http://127.0.0.1:9222/json", timeout=8) as r:
        return json.loads(r.read().decode())

def find_serp_tab():
    try:
        pages = [t for t in get_tabs() if t.get("type") == "page"]
        pages.sort(key=lambda t: 0 if "bing." in t.get("url", "").lower() else 1)
        return pages[0] if pages else None
    except Exception:
        return None

def find_target_tab():
    try:
        for t in get_tabs():
            if t.get("type") != "page":
                continue
            u = t.get("url", "").lower()
            if HOST in u and "bing." not in u and "chrome-error" not in u:
                return t
    except Exception:
        pass
    return None

tab = None
for attempt in range(50):
    tab = find_serp_tab()
    if tab:
        break
    if attempt % 10 == 0:
        print(f"waiting for SERP tab... ({attempt})", flush=True)
    time.sleep(1.5)

if not tab:
    print("DevTools tab not reachable", flush=True)
    sys.exit(2)

print("attached to:", tab.get("url"), flush=True)
print("Spoofing as:", IPHONE_NAME, flush=True)

ws = websocket.create_connection(
    tab["webSocketDebuggerUrl"],
    timeout=120, suppress_origin=True,
    ping_interval=12, ping_timeout=8
)

_id = 0
def cdp(method, **params):
    global _id, ws, tab
    for attempt in range(4):
        try:
            _id += 1
            ws.send(json.dumps({"id": _id, "method": method, "params": params}))
            deadline = time.time() + 25
            while time.time() < deadline:
                msg = json.loads(ws.recv())
                if msg.get("id") == _id:
                    return msg.get("result", {})
        except Exception as e:
            print(f"CDP error ({attempt+1}): {e}", flush=True)
            try:
                ws.close()
            except Exception:
                pass
            time.sleep(2)
            new = find_target_tab() or find_serp_tab()
            if not new:
                raise
            tab = new
            ws = websocket.create_connection(
                tab["webSocketDebuggerUrl"],
                timeout=120, suppress_origin=True,
                ping_interval=12, ping_timeout=8
            )
    raise RuntimeError("CDP failed")

def js(expr):
    r = cdp("Runtime.evaluate", expression=expr, returnByValue=True)
    return r.get("result", {}).get("value")

cdp("Page.enable")
cdp("Runtime.enable")
cdp("Network.enable")

print("Applying iPhone UA...", flush=True)
cdp("Network.setUserAgentOverride",
    userAgent=IPHONE_UA,
    platform="iPhone",
    acceptLanguage="en-US,en;q=0.9")
print("iPhone UA applied:", IPHONE_NAME, flush=True)

# ---------- BING ORGANIC CLICK (improved matcher) ----------
print("=== BING ORGANIC CLICK (up to 3 SERP pages) ===", flush=True)
print(f"Looking for domain={HOST} keyword={TARGET}", flush=True)

KW_TOKENS = [w for w in TARGET.replace("-", " ").split() if len(w) > 2][:8]
SERP_URL = js("location.href") or ""

FIND_JS = """(() => {
  const HOST = %s;
  const TOKENS = %s;
  const vis = e => {
    const r = e.getBoundingClientRect(), st = getComputedStyle(e);
    return r.width > 6 && r.height > 6 && st.visibility !== 'hidden' && st.display !== 'none';
  };

  // Bing organic cards
  const cards = [
    ...document.querySelectorAll('li.b_algo, .b_algo, [class*="algo"], article, .b_results > li')
  ];
  // Fallback: any block that mentions our domain in text
  const extra = [...document.querySelectorAll('li, div, section')].filter(el => {
    const t = (el.innerText || '').toLowerCase();
    return t.includes(HOST) || t.includes('gardengar');
  });
  const blocks = cards.length ? cards : extra;

  const candidates = [];
  for (const card of blocks) {
    const text = (card.innerText || '').toLowerCase();
    if (!text.includes(HOST) && !text.includes('gardengar')) continue;

    // Prefer real outbound link; else title link inside card
    let a = [...card.querySelectorAll('a[href]')].find(x => {
      const h = (x.href || '').toLowerCase();
      return h.includes(HOST) && !h.includes('bing.com');
    });
    if (!a) {
      a = card.querySelector('h2 a, h3 a, a[hres], a') || card.querySelector('a[href]');
    }
    if (!a || !vis(a)) continue;

    let score = 25; // domain in card text
    const href = (a.href || '').toLowerCase();
    if (href.includes(HOST)) score += 15;
    if (a.querySelector('h2, h3') || a.closest('h2, h3')) score += 8;
    for (const t of TOKENS) {
      if (text.includes(t)) score += 2;
    }

    const titleEl = card.querySelector('h2, h3, [role=heading]') || a;
    const r = titleEl.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) continue;

    candidates.push({
      tag: titleEl.tagName,
      text: (titleEl.innerText || a.innerText || '').trim().slice(0, 120),
      href: a.href,
      x: r.left + r.width / 2,
      y: r.top + r.height / 2,
      score
    });
  }

  candidates.sort((x, y) => y.score - x.score);
  const titles = [...document.querySelectorAll('h2, h3, [role=heading], cite')]
    .map(e => (e.innerText || '').trim()).filter(Boolean).slice(0, 20);
  return JSON.stringify({
    found: candidates[0] || null,
    count: candidates.length,
    titles,
    innerH: window.innerHeight,
    innerW: window.innerWidth,
    scrollY: window.scrollY,
    maxY: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
  });
})()""" % (json.dumps(HOST), json.dumps(KW_TOKENS))

NEXT_JS = """(() => {
  const vis = e => {
    const r = e.getBoundingClientRect(), st = getComputedStyle(e);
    return r.width > 8 && r.height > 8 && st.visibility !== 'hidden' && st.display !== 'none';
  };
  const labels = ['next', 'next page', '›', '>', '下一页'];
  for (const a of document.querySelectorAll('a, button, [role=button], [role=link]')) {
    if (!vis(a)) continue;
    const t = ((a.innerText || '') + ' ' + (a.getAttribute('aria-label') || '') +
               ' ' + (a.getAttribute('title') || '')).trim().toLowerCase();
    if (labels.some(l => t === l || t.startsWith('next'))) {
      const r = a.getBoundingClientRect();
      return JSON.stringify({
        x: r.left + r.width / 2,
        y: r.top + r.height / 2,
        text: t.slice(0, 40)
      });
    }
  }
  // Bing often uses sb_pagN / "Next"
  for (const a of document.querySelectorAll('a[href*="first="], a.sb_pagN, a[aria-label*="Next" i]')) {
    if (!vis(a)) continue;
    const r = a.getBoundingClientRect();
    return JSON.stringify({
      x: r.left + r.width / 2,
      y: r.top + r.height / 2,
      text: (a.innerText || 'next').slice(0, 40)
    });
  }
  return 'null';
})()"""

def smooth_scroll(dist, x, y):
    cdp("Input.synthesizeScrollGesture", x=x, y=y, yDistance=-dist,
        speed=450, gestureSourceType="touch")
    time.sleep(1.15)

def is_target(url):
    u = (url or "").lower()
    return HOST in u and "bing." not in u and "chrome-error" not in u

def ensure_on_serp():
    try:
        cur = (js("location.href") or "").lower()
        if "bing." in cur and "search" in cur:
            return True
        if is_target(cur):
            return False  # already on site
    except Exception:
        pass
    print("  navigating back to SERP...", flush=True)
    try:
        cdp("Page.navigate", url=SERP_URL)
        time.sleep(4)
    except Exception:
        pass
    return True

def try_find_and_click_on_current_page(page_num):
    """Scroll current SERP page looking for domain. Returns True if landed on target."""
    print(f"\n--- SERP page {page_num}/3 ---", flush=True)
    stale_bottom = 0
    for attempt in range(45):
        if not ensure_on_serp():
            # already on target
            return True
        try:
            cur = (js("location.href") or "").lower()
            if is_target(cur):
                print("SUCCESS: on target", flush=True)
                return True
        except Exception:
            pass

        info = json.loads(js(FIND_JS) or "{}")
        found = info.get("found")
        H = info.get("innerH", 800)
        W = info.get("innerW", 400)
        scrollY = info.get("scrollY", 0)
        maxY = info.get("maxY", 0)

        if attempt % 8 == 0:
            print(f"  candidates={info.get('count', 0)} scroll={scrollY:.0f}/{maxY:.0f}", flush=True)
            if info.get("titles"):
                print(f"  titles: {info.get('titles')[:4]}", flush=True)

        if found and 40 < found["y"] < H - 40:
            print(f"found '{found['text']}' score={found.get('score')}", flush=True)
            cdp("Input.synthesizeTapGesture", x=found["x"], y=found["y"])
            print("real organic tap", flush=True)
            for w in range(18):
                time.sleep(1.3)
                try:
                    now = (js("location.href") or "").lower()
                    if is_target(now):
                        print("SUCCESS: organic landing →", now[:90], flush=True)
                        return True
                except Exception:
                    pass
                t = find_target_tab()
                if t:
                    global tab, ws
                    try:
                        ws.close()
                    except Exception:
                        pass
                    tab = t
                    ws = websocket.create_connection(
                        tab["webSocketDebuggerUrl"], timeout=120,
                        suppress_origin=True, ping_interval=12, ping_timeout=8
                    )
                    cdp("Page.enable"); cdp("Runtime.enable"); cdp("Network.enable")
                    cdp("Network.setUserAgentOverride", userAgent=IPHONE_UA, platform="iPhone")
                    print("SUCCESS: target tab", flush=True)
                    return True
            print("  tap missed domain – stay on SERP / go back", flush=True)
            ensure_on_serp()
            time.sleep(1.5)
            continue

        if found:
            smooth_scroll(int(found["y"] - H / 2), int(W / 2), int(H * 0.55))
        else:
            if maxY > 0 and scrollY >= maxY - 40:
                stale_bottom += 1
                if stale_bottom >= 3:
                    print(f"  end of SERP page {page_num}", flush=True)
                    break
                smooth_scroll(-int(H * 0.25), int(W / 2), int(H * 0.5))
                time.sleep(0.7)
            else:
                stale_bottom = 0
            smooth_scroll(int(H * 0.38), int(W / 2), int(H * 0.62))
    return False

def go_to_next_serp_page():
    """Tap Bing Next. Returns True if navigation likely happened."""
    print("  looking for Next page control...", flush=True)
    # Scroll near bottom so Next is visible
    for _ in range(4):
        info = json.loads(js(FIND_JS) or "{}")
        H = info.get("innerH", 800)
        W = info.get("innerW", 400)
        maxY = info.get("maxY", 0)
        scrollY = info.get("scrollY", 0)
        if maxY > 0 and scrollY >= maxY - 80:
            break
        smooth_scroll(int(H * 0.45), int(W / 2), int(H * 0.65))

    raw = js(NEXT_JS) or "null"
    if raw == "null" or raw is None:
        print("  Next control not found", flush=True)
        return False
    try:
        nxt = json.loads(raw)
    except Exception:
        print("  Next parse failed", flush=True)
        return False
    print(f"  tapping Next: {nxt.get('text')}", flush=True)
    old = (js("location.href") or "")
    cdp("Input.synthesizeTapGesture", x=nxt["x"], y=nxt["y"])
    time.sleep(4.5)
    new = (js("location.href") or "")
    if new != old or "first=" in new.lower() or "first=" in (js("location.href") or "").lower():
        print("  moved to next SERP page", flush=True)
        time.sleep(2)
        return True
    # soft navigate via URL first= param if still same
    try:
        from urllib.parse import urlparse, parse_qs, urlencode, urlunparse
        u = urlparse(old)
        qs = parse_qs(u.query)
        first = int(qs.get("first", ["1"])[0])
        qs["first"] = [str(first + 10)]
        new_q = urlencode({k: v[0] if len(v) == 1 else v for k, v in qs.items()}, doseq=True)
        next_url = urlunparse((u.scheme, u.netloc, u.path, u.params, new_q, u.fragment))
        cdp("Page.navigate", url=next_url)
        time.sleep(4)
        print("  navigated via first= param", flush=True)
        return True
    except Exception as e:
        print(f"  next page fallback failed: {e}", flush=True)
        return False

# ----- try up to 3 SERP pages -----
success = False
for page_num in range(1, 4):
    if try_find_and_click_on_current_page(page_num):
        success = True
        break
    if page_num < 3:
        if not go_to_next_serp_page():
            print("  cannot open next page – stop SERP search", flush=True)
            break
        SERP_URL = js("location.href") or SERP_URL

if not success:
    # Soft skip: do NOT fail the job so chain continues
    print("SKIP: domain not found on 3 SERP pages – continuing chain", flush=True)
    try:
        with open(os.path.join(ARTIFACTS, "page-debug.json"), "w") as f:
            f.write(js(FIND_JS) or "{}")
    except Exception:
        pass
    subprocess.run(["adb", "exec-out", "screencap", "-p"],
                   stdout=open(os.path.join(ARTIFACTS, "03-skipped-no-result.png"), "wb"),
                   check=False)
    ws.close()
    print("SOFT_EXIT_SKIP", flush=True)
    sys.exit(0)   # success for GitHub → next run is dispatched

# --- only if success: screenshots + engagement (keep your existing engagement code below) ---
subprocess.run(["adb", "exec-out", "screencap", "-p"],
               stdout=open(os.path.join(ARTIFACTS, "03-organic-landed.png"), "wb"), check=False)
time.sleep(2)
subprocess.run(["adb", "exec-out", "screencap", "-p"],
               stdout=open(os.path.join(ARTIFACTS, "04-organic-settled.png"), "wb"), check=False)
# ---------- ENGAGEMENT ----------
print("\n=== ENGAGEMENT ===", flush=True)

def page_dims():
    return json.loads(js("""(() => JSON.stringify({
        H: window.innerHeight, W: window.innerWidth,
        scrollY: window.scrollY,
        maxY: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
    }))()""") or "{}")

def smooth_scroll_random(sec):
    end = time.time() + sec
    count = 0
    while True:
        remaining = end - time.time()
        if remaining <= 0.4:
            break
        d = page_dims()
        H, W = d.get("H", 800), d.get("W", 400)
        maxY, curY = d.get("maxY", 0), d.get("scrollY", 0)
        if curY >= maxY - 30 and maxY > 0:
            direction = 1
        elif curY < 40:
            direction = -1
        else:
            direction = -1 if random.random() < 0.75 else 1
        try:
            cdp("Input.synthesizeScrollGesture",
                x=int(W * random.uniform(0.3, 0.7)),
                y=int(H * random.uniform(0.4, 0.7)),
                yDistance=direction * random.randint(int(H * 0.22), int(H * 0.48)),
                speed=random.randint(220, 420),
                gestureSourceType="touch")
            count += 1
        except Exception as e:
            print(f"scroll err: {e}", flush=True)
        pause = random.uniform(2.2, 5.0)
        remaining = end - time.time()
        if remaining <= 0:
            break
        time.sleep(min(pause, remaining))
    print(f"  {count} scrolls", flush=True)

def find_good_links():
    raw = js("""(() => {
        const host = location.hostname.replace(/^www\\./,'').replace(/^m\\./,'');
        const bad = ['/about','/contact','/privacy','/terms','/licensing','/cookie'];
        const vis = e => {
            const r = e.getBoundingClientRect(), st = getComputedStyle(e);
            return r.width > 12 && r.height > 12 && st.visibility !== 'hidden' && st.display !== 'none';
        };
        const links = [...document.querySelectorAll('a[href]')].filter(a => {
            try {
                const u = new URL(a.href, location.href);
                if (u.hostname.replace(/^www\\./,'').replace(/^m\\./,'') !== host) return false;
                if (bad.some(b => u.pathname.toLowerCase().includes(b))) return false;
                if (u.hash && u.pathname === location.pathname) return false;
                return vis(a);
            } catch(e) { return false; }
        });
        const score = a => {
            let s = 0;
            const t = (a.innerText || '').trim().toLowerCase(), href = a.href.toLowerCase();
            if (/\\/20[0-9]{2}\\//.test(href) || /\\/blog\\//.test(href)) s += 8;
            if (a.querySelector('h1,h2,h3,h4')) s += 5;
            if (t.length > 25 && t.length < 120) s += 3;
            return s;
        };
        links.sort((x, y) => score(y) - score(x));
        return JSON.stringify(links.slice(0, 18).map(a => {
            const t = a.querySelector('h1,h2,h3,h4') || a;
            const r = t.getBoundingClientRect();
            return {text: (t.innerText||'').trim().slice(0,80), href: a.href,
                    x: r.left+r.width/2, y: r.top+r.height/2, score: score(a)};
        }));
    })()""")
    try:
        return json.loads(raw or "[]")
    except Exception:
        return []

visited = set()
current = js("location.href") or ""
print("starting on:", current, flush=True)

for page_num in range(1, NUM_PAGES + 1):
    print(f"\n===== PAGE {page_num}/{NUM_PAGES} =====", flush=True)
    dwell = random.randint(MIN_DWELL, MAX_DWELL)
    print(f"  dwell ~{dwell}s", flush=True)
    smooth_scroll_random(dwell)
    try:
        name = f"0{4 + page_num}-page{page_num}.png"
        subprocess.run(["adb", "exec-out", "screencap", "-p"],
                       stdout=open(os.path.join(ARTIFACTS, name), "wb"), check=False)
    except Exception:
        pass
    if page_num >= NUM_PAGES:
        break
    links = find_good_links()
    candidates = [L for L in links if L["href"] not in visited and L.get("score", 0) >= 3] \
                 or [L for L in links if L["href"] not in visited]
    if not candidates:
        print("  no more links", flush=True)
        break
    choice = random.choice(sorted(candidates, key=lambda x: x.get("score", 0), reverse=True)[:6])
    visited.add(choice["href"])
    print(f"  tap '{choice['text'][:50]}'", flush=True)
    old = (js("location.href") or "").rstrip("/")
    cdp("Input.synthesizeTapGesture", x=choice["x"], y=choice["y"])
    time.sleep(random.uniform(5.5, 8.0))
    new = (js("location.href") or "").rstrip("/")
    if new == old and choice["href"] not in new:
        cdp("Page.navigate", url=choice["href"])
        time.sleep(3.5)
    print("  now:", js("location.href"), flush=True)

print("\n===== FINAL =====", flush=True)
smooth_scroll_random(random.randint(40, 70))
subprocess.run(["adb", "exec-out", "screencap", "-p"],
               stdout=open(os.path.join(ARTIFACTS, "09-final.png"), "wb"), check=False)
print("visited:", list(visited), flush=True)
ws.close()
print("DONE – Bing iPhone organic + engagement finished", flush=True)
PY
}

# ===================== MAIN =====================
log "waiting for first boot"
wait_for_boot
if ensure_root; then HAVE_ROOT=1; fi
settle_device
pick_iphone_profile
dump_identity
resolve_chrome
skip_chrome_welcome

open_url "$TARGET_URL"
sleep 6
dismiss_chrome_sheets
screenshot "01-bing-home.png"

open_url "$SEARCH_URL"
sleep 10
dismiss_chrome_sheets
screenshot "02-search-results.png"

if ! wait_for_devtools 30; then
  log "DevTools not ready – restart Chrome and retry search page"
  open_url "$SEARCH_URL"
  sleep 12
  dismiss_chrome_sheets
  if ! wait_for_devtools 35; then
    log "DevTools still not reachable – aborting"
    screenshot "03-failed.png"
    exit 1
  fi
fi

log "Starting Bing organic traffic as $IPHONE_NAME"
if do_organic_and_engage; then
  screenshot "10-engagement-done.png"
  log "SUCCESS – appeared as $IPHONE_NAME"
else
  log "FAILED"
  screenshot "03-failed.png"
  exit 1
fi

log "done"
ls -la "$ARTIFACTS"
