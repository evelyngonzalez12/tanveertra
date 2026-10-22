#!/usr/bin/env bash
# Bing organic – Android multi-device
# Page 1 only, multi-keyword until domain found.
# Artifacts: ONLY on failure (full SERP scrape + debug). No success page screenshots.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
ARTIFACTS="${ROOT}/artifacts"
mkdir -p "$ARTIFACTS"

CHROME_PKG="com.android.chrome"
HAVE_ROOT=0
BRAND=""; MODEL=""; NAME=""; DEVICE=""; MARKETNAME=""; FINGERPRINT=""; SDK="14"; DENSITY="420"

log() { printf '[capture] %s\n' "$*"; }
adb_sh() { adb shell "$@" | tr -d '\r'; }

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
if ((${#KW_ARR[@]} > 1)); then
  mapfile -t KW_ARR < <(printf '%s\n' "${KW_ARR[@]}" | shuf)
fi

log "Target domain: $RESULT_HOST"
log "Keyword pool (${#KW_ARR[@]}): ${KW_ARR[*]}"
TARGET_URL="https://www.bing.com"
export RESULT_HOST TARGET_URL

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

pick_android_device() {
  local devices=(
    "samsung|SM-S928B|e3sxxx|e3s|Galaxy S24 Ultra|samsung/e3sxxx/e3s:14/UP1A.231005.007/S928BXXS3AXKF:user/release-keys|14|420"
    "samsung|SM-S911B|dm1q|dm1q|Galaxy S23|samsung/dm1qxxx/dm1q:14/UP1A.231005.007/S911BXXS3AXK1:user/release-keys|14|420"
    "samsung|SM-A556B|a55x|a55x|Galaxy A55|samsung/a55xxx/a55x:14/UP1A.231005.007/A556BXXS3AXK1:user/release-keys|14|420"
    "google|Pixel 8 Pro|husky|husky|Pixel 8 Pro|google/husky/husky:14/AP2A.240905.003/12234114:user/release-keys|14|420"
    "google|Pixel 7|panther|panther|Pixel 7|google/panther/panther:14/AP2A.240905.003/12234114:user/release-keys|14|420"
    "google|Pixel 6a|bluejay|bluejay|Pixel 6a|google/bluejay/bluejay:14/AP2A.240905.003/12234114:user/release-keys|14|420"
    "OnePlus|CPH2449|OPD2101|OPD2101|OnePlus 11|OnePlus/CPH2449/OPD2101:14/UKQ1.230924.001/R.19a:user/release-keys|14|480"
    "Xiaomi|23013PC75G|fuxi|fuxi|Xiaomi 13|Xiaomi/fuxi/fuxi:14/UKQ1.230917.001/V14.0.5.0:user/release-keys|14|440"
    "samsung|SM-G991B|o1s|o1s|Galaxy S21|samsung/o1sxxx/o1s:13/TP1A.220624.014/G991BXXS6DWL1:user/release-keys|13|420"
    "motorola|XT2301-4|rtwo|rtwo|moto g power 5G|motorola/rtwo/rtwo:14/U1TR34.29-61/61:user/release-keys|14|400"
  )
  local choice="${devices[RANDOM % ${#devices[@]}]}"
  IFS='|' read -r BRAND MODEL NAME DEVICE MARKETNAME FINGERPRINT SDK DENSITY <<< "$choice"
  log "Selected device: $MARKETNAME ($MODEL) Android $SDK"
}

write_device_identity() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<PROP
ro.product.brand=${BRAND}
ro.product.manufacturer=${BRAND}
ro.product.model=${MODEL}
ro.product.name=${NAME}
ro.product.device=${DEVICE}
ro.product.marketname=${MARKETNAME}
ro.build.fingerprint=${FINGERPRINT}
ro.build.type=user
ro.build.tags=release-keys
ro.build.version.release=${SDK}
ro.build.version.sdk=${SDK}
ro.sf.lcd_density=${DENSITY}
PROP
  adb push "$tmp" /data/local.prop
  adb_sh chmod 644 /data/local.prop
  rm -f "$tmp"
  log "pushed /data/local.prop → $MARKETNAME"
}

dump_identity() {
  {
    echo "=== shell ==="; adb_sh id || true
    echo; echo "=== identity ==="
    for key in ro.product.brand ro.product.manufacturer ro.product.model \
      ro.product.name ro.product.device ro.product.marketname \
      ro.build.fingerprint ro.build.version.release ro.build.version.sdk \
      persist.sys.locale persist.sys.timezone; do
      printf '%s=%s\n' "$key" "$(adb_sh getprop "$key")"
    done
    echo; echo "=== selected profile ==="
    echo "marketname=$MARKETNAME model=$MODEL brand=$BRAND sdk=$SDK"
    echo "domain=$RESULT_HOST"
    echo "keywords=${KW_ARR[*]}"
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
      adb forward --remove tcp:9222 >/dev/null 2>&1 || true
      adb forward tcp:9222 localabstract:chrome_devtools_remote >/dev/null 2>&1 || true
    fi
  done
  log "DevTools wait timed out after ${max} attempts"
  return 1
}

# Only used on FAILURE
screenshot_fail() {
  adb exec-out screencap -p > "${ARTIFACTS}/$1" 2>/dev/null || true
  log "FAIL artifact: ${ARTIFACTS}/$1"
}

settle_device() {
  adb shell svc power stayon true >/dev/null || true
  adb shell settings put global stay_on_while_plugged_in 3 >/dev/null || true
  adb shell settings put secure lockscreen.disabled 1 >/dev/null || true
  adb shell locksettings set-disabled true >/dev/null 2>&1 || true
  adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb_sh wm size 1080x2340 || true
  adb_sh wm density "${DENSITY:-420}" || true
}

install_websocket() {
  log "Installing websocket-client..."
  python3 -m pip install -q websocket-client --break-system-packages >/dev/null 2>&1 \
    || python3 -m pip install -q websocket-client >/dev/null 2>&1 || true
  if python3 -c "import websocket" 2>/dev/null; then
    log "websocket-client OK"
    return 0
  fi
  log "ERROR: websocket module still missing"
  return 1
}

try_keyword() {
  local keyword="$1"
  local encoded
  encoded="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$keyword")"
  local search_url="https://www.bing.com/search?q=${encoded}"
  local safe_kw
  safe_kw="$(echo "$keyword" | tr ' /' '__' | tr -cd '[:alnum:]_-' | cut -c1-40)"

  log "Trying keyword: $keyword"
  open_url "$search_url"
  sleep 8
  dismiss_chrome_sheets

  if ! wait_for_devtools 25; then
    log "DevTools not ready – retry open"
    open_url "$search_url"
    sleep 10
    dismiss_chrome_sheets
    wait_for_devtools 30 || { log "DevTools failed for this keyword"; return 1; }
  fi

  RESULT_TEXT="$keyword" \
  RESULT_HOST="$RESULT_HOST" \
  ARTIFACTS="$ARTIFACTS" \
  SAFE_KW="$safe_kw" \
  python3 - <<'PY'
import json, os, sys, time, random, urllib.request, subprocess, base64, re
import websocket

HOST = os.environ["RESULT_HOST"].strip().lower().replace("www.", "")
TARGET = os.environ["RESULT_TEXT"].strip().lower()
ARTIFACTS = os.environ["ARTIFACTS"]
SAFE_KW = os.environ.get("SAFE_KW", "kw")

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
for attempt in range(30):
    tab = find_serp_tab()
    if tab:
        break
    time.sleep(1.2)
if not tab:
    print("NO_TAB", flush=True)
    sys.exit(1)

print("attached:", tab.get("url"), flush=True)
ws = websocket.create_connection(
    tab["webSocketDebuggerUrl"], timeout=120, suppress_origin=True,
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
            print(f"CDP err ({attempt+1}): {e}", flush=True)
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
                tab["webSocketDebuggerUrl"], timeout=120, suppress_origin=True,
                ping_interval=12, ping_timeout=8
            )
    raise RuntimeError("CDP failed")

def js(expr):
    r = cdp("Runtime.evaluate", expression=expr, returnByValue=True)
    return r.get("result", {}).get("value")

cdp("Page.enable")
cdp("Runtime.enable")
cdp("Network.enable")
print(f"domain={HOST}  keyword={TARGET}", flush=True)

KW_TOKENS = [w for w in TARGET.replace("-", " ").split() if len(w) > 2][:8]

# Full SERP scrape – all organic results with decoded Bing redirects
SCRAPE_JS = r"""(() => {
  const HOST = %s;
  function decodeBingHref(href) {
    try {
      const u = new URL(href, location.href);
      // Bing ck redirect: &u=a1XXXX (base64 of target URL after a1 prefix)
      const uParam = u.searchParams.get('u');
      if (uParam) {
        let raw = uParam;
        if (raw.startsWith('a1')) raw = raw.slice(2);
        try {
          const pad = '='.repeat((4 - (raw.length %% 4)) %% 4);
          const decoded = atob(raw + pad);
          if (decoded.startsWith('http')) return decoded;
        } catch (e) {}
        try {
          // sometimes URL-safe base64
          raw = raw.replace(/-/g, '+').replace(/_/g, '/');
          const pad = '='.repeat((4 - (raw.length %% 4)) %% 4);
          const decoded = atob(raw + pad);
          if (decoded.startsWith('http')) return decoded;
        } catch (e) {}
      }
      // r= parameter
      const r = u.searchParams.get('r');
      if (r && r.startsWith('http')) return r;
    } catch (e) {}
    return href;
  }
  function hostOf(url) {
    try {
      return new URL(url).hostname.replace(/^www\./, '').toLowerCase();
    } catch (e) {
      return '';
    }
  }
  const vis = e => {
    const r = e.getBoundingClientRect(), st = getComputedStyle(e);
    return r.width > 4 && r.height > 4 && st.visibility !== 'hidden' && st.display !== 'none';
  };
  const results = [];
  const seen = new Set();
  // Prefer classic Bing organic cards
  let cards = [...document.querySelectorAll('li.b_algo, .b_algo, #b_results > li, .b_results > li')];
  if (!cards.length) {
    cards = [...document.querySelectorAll('#b_results li, ol#b_results > li, [data-bm]')];
  }
  // Fallback: any block that looks like a result
  if (!cards.length) {
    cards = [...document.querySelectorAll('main li, #b_content li')].filter(el => {
      return el.querySelector('h2, h3, a') && (el.innerText || '').length > 30;
    });
  }
  for (const card of cards) {
    const citeEl = card.querySelector('cite, .b_attribution, .b_cite, [class*="cite"]');
    const citeText = (citeEl ? citeEl.innerText : '') || '';
    const titleEl = card.querySelector('h2, h3, [role="heading"]') || card.querySelector('a');
    const title = (titleEl ? titleEl.innerText : '').trim().slice(0, 160);
    const links = [...card.querySelectorAll('a[href]')];
    let bestHref = '';
    let decoded = '';
    let domain = '';
    for (const a of links) {
      const href = a.href || '';
      if (!href || href.startsWith('javascript:')) continue;
      const d = decodeBingHref(href);
      const h = hostOf(d);
      if (!h || h.includes('bing.com') || h.includes('microsoft.com') || h.includes('msn.com')) continue;
      bestHref = href;
      decoded = d;
      domain = h;
      break;
    }
    // Domain from cite if href decode failed
    if (!domain && citeText) {
      const m = citeText.toLowerCase().match(/([a-z0-9][-a-z0-9]*\.(?:com|net|org|io|co|uk|info|biz|app)(?:\.[a-z]{2})?)/);
      if (m) domain = m[1].replace(/^www\./, '');
    }
    if (!domain && !title) continue;
    const key = domain + '|' + title.slice(0, 40);
    if (seen.has(key)) continue;
    seen.add(key);
    const tapEl = titleEl || links[0] || card;
    const r = tapEl.getBoundingClientRect();
    const cardText = (card.innerText || '').toLowerCase();
    results.push({
      position: results.length + 1,
      domain: domain,
      title: title,
      cite: citeText.trim().slice(0, 120),
      href: bestHref.slice(0, 300),
      decoded_url: decoded.slice(0, 300),
      is_target: domain.includes(HOST) || cardText.includes(HOST) || (decoded || '').toLowerCase().includes(HOST),
      x: r.left + r.width / 2,
      y: r.top + r.height / 2,
      visible: vis(tapEl)
    });
  }
  // Also collect every unique external domain from any link on page (extra safety)
  const allDomains = [];
  const domSeen = new Set();
  for (const a of document.querySelectorAll('a[href]')) {
    const d = hostOf(decodeBingHref(a.href || ''));
    if (!d || d.includes('bing.') || d.includes('microsoft.') || d.includes('msn.') || d.includes('live.com')) continue;
    if (domSeen.has(d)) continue;
    domSeen.add(d);
    allDomains.push(d);
  }
  return JSON.stringify({
    page_url: location.href,
    page_title: document.title,
    result_count: results.length,
    target_host: HOST,
    target_found_in_results: results.some(r => r.is_target),
    target_found_in_all_domains: allDomains.some(d => d.includes(HOST)),
    results: results,
    all_domains_on_page: allDomains,
    innerH: window.innerHeight,
    innerW: window.innerWidth,
    scrollY: window.scrollY,
    maxY: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
  });
})()""" % json.dumps(HOST)

# Finder: match target using scrape data + decode
FIND_JS = r"""(() => {
  const HOST = %s;
  const TOKENS = %s;
  function decodeBingHref(href) {
    try {
      const u = new URL(href, location.href);
      const uParam = u.searchParams.get('u');
      if (uParam) {
        let raw = uParam.startsWith('a1') ? uParam.slice(2) : uParam;
        for (const r of [raw, raw.replace(/-/g, '+').replace(/_/g, '/')]) {
          try {
            const pad = '='.repeat((4 - (r.length %% 4)) %% 4);
            const decoded = atob(r + pad);
            if (decoded.startsWith('http')) return decoded;
          } catch (e) {}
        }
      }
    } catch (e) {}
    return href;
  }
  function hostOf(url) {
    try { return new URL(url).hostname.replace(/^www\./, '').toLowerCase(); } catch (e) { return ''; }
  }
  const vis = e => {
    const r = e.getBoundingClientRect(), st = getComputedStyle(e);
    return r.width > 6 && r.height > 6 && st.visibility !== 'hidden' && st.display !== 'none';
  };
  let cards = [...document.querySelectorAll('li.b_algo, .b_algo, #b_results > li, .b_results > li')];
  if (!cards.length) cards = [...document.querySelectorAll('#b_results li, [data-bm]')];
  if (!cards.length) {
    cards = [...document.querySelectorAll('main li, #b_content li')].filter(el =>
      el.querySelector('h2,h3,a') && (el.innerText||'').length > 30);
  }
  const candidates = [];
  for (const card of cards) {
    const text = (card.innerText || '').toLowerCase();
    const cite = ((card.querySelector('cite, .b_attribution, .b_cite') || {}).innerText || '').toLowerCase();
    let matched = text.includes(HOST) || cite.includes(HOST);
    let a = null;
    let decoded = '';
    for (const link of card.querySelectorAll('a[href]')) {
      const d = decodeBingHref(link.href || '');
      const h = hostOf(d);
      if (h.includes(HOST) || d.toLowerCase().includes(HOST)) {
        matched = true;
        a = link;
        decoded = d;
        break;
      }
    }
    if (!matched) continue;
    if (!a) a = card.querySelector('h2 a, h3 a, a');
    if (!a || !vis(a)) continue;
    let score = 30;
    if (cite.includes(HOST) || text.includes(HOST)) score += 20;
    if (decoded.toLowerCase().includes(HOST) || (a.href || '').toLowerCase().includes(HOST)) score += 15;
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
      decoded: decoded.slice(0, 200),
      x: r.left + r.width / 2,
      y: r.top + r.height / 2,
      score
    });
  }
  candidates.sort((x, y) => y.score - x.score);
  return JSON.stringify({
    found: candidates[0] || null,
    count: candidates.length,
    innerH: window.innerHeight,
    innerW: window.innerWidth,
    scrollY: window.scrollY,
    maxY: Math.max(0, document.documentElement.scrollHeight - window.innerHeight)
  });
})()""" % (json.dumps(HOST), json.dumps(KW_TOKENS))


def save_fail_debug(reason):
    """Scrape full page-1 results and write fail-only artifacts."""
    try:
        scrape = js(SCRAPE_JS) or "{}"
        data = json.loads(scrape)
    except Exception as e:
        data = {"error": str(e), "raw": None}
        scrape = json.dumps(data)
    path_json = os.path.join(ARTIFACTS, f"FAIL-serp-{SAFE_KW}.json")
    path_txt = os.path.join(ARTIFACTS, f"FAIL-serp-{SAFE_KW}.txt")
    with open(path_json, "w") as f:
        f.write(json.dumps(data, indent=2))
    lines = [
        f"keyword: {TARGET}",
        f"target_domain: {HOST}",
        f"reason: {reason}",
        f"page_url: {data.get('page_url', '')}",
        f"target_found_in_results: {data.get('target_found_in_results')}",
        f"target_found_in_all_domains: {data.get('target_found_in_all_domains')}",
        f"result_count: {data.get('result_count')}",
        "",
        "=== ALL DOMAINS ON PAGE 1 ===",
    ]
    for d in data.get("all_domains_on_page") or []:
        mark = " <<<< TARGET" if HOST in d else ""
        lines.append(f"  - {d}{mark}")
    lines.append("")
    lines.append("=== ORGANIC RESULTS (position, domain, title) ===")
    for r in data.get("results") or []:
        mark = " <<<< TARGET MATCH" if r.get("is_target") else ""
        lines.append(f"  #{r.get('position')}  domain={r.get('domain')}{mark}")
        lines.append(f"      title: {r.get('title')}")
        lines.append(f"      cite:  {r.get('cite')}")
        lines.append(f"      decoded: {r.get('decoded_url', '')[:120]}")
        lines.append(f"      xy=({r.get('x'):.0f},{r.get('y'):.0f}) visible={r.get('visible')}")
    with open(path_txt, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"FAIL debug written: {path_txt}", flush=True)
    print(f"  target_found_in_results={data.get('target_found_in_results')} domains={data.get('all_domains_on_page')}", flush=True)
    # screenshot only on fail
    try:
        subprocess.run(
            ["adb", "exec-out", "screencap", "-p"],
            stdout=open(os.path.join(ARTIFACTS, f"FAIL-serp-{SAFE_KW}.png"), "wb"),
            check=False,
        )
    except Exception:
        pass
    return data


def smooth_scroll(dist, x, y):
    cdp("Input.synthesizeScrollGesture", x=x, y=y, yDistance=-dist,
        speed=450, gestureSourceType="touch")
    time.sleep(1.1)


def is_target(url):
    u = (url or "").lower()
    return HOST in u and "bing." not in u and "chrome-error" not in u


# Wait for results to paint
for _ in range(10):
    try:
        body = js("document.body && document.body.innerText ? document.body.innerText.length : 0") or 0
        if body > 400:
            break
    except Exception:
        pass
    time.sleep(1)

print("=== SERP page 1 only ===", flush=True)
# Initial scrape log (console only – not artifact unless fail)
try:
    pre = json.loads(js(SCRAPE_JS) or "{}")
    print(f"  scrape: {pre.get('result_count', 0)} results, domains={pre.get('all_domains_on_page', [])[:12]}", flush=True)
    print(f"  target_in_results={pre.get('target_found_in_results')} target_in_domains={pre.get('target_found_in_all_domains')}", flush=True)
except Exception as e:
    print(f"  pre-scrape err: {e}", flush=True)

success = False
stale_bottom = 0
for attempt in range(40):
    try:
        cur = (js("location.href") or "").lower()
        if is_target(cur):
            print("SUCCESS already on target", flush=True)
            success = True
            break
    except Exception:
        pass

    info = json.loads(js(FIND_JS) or "{}")
    found = info.get("found")
    H = info.get("innerH", 800)
    W = info.get("innerW", 400)
    scrollY = info.get("scrollY", 0)
    maxY = info.get("maxY", 0)

    if attempt % 5 == 0:
        print(f"  attempt={attempt} candidates={info.get('count', 0)} scroll={scrollY:.0f}/{maxY:.0f}", flush=True)
        if found:
            print(f"  best: '{found.get('text', '')[:60]}' score={found.get('score')}", flush=True)

    if found and 30 < found["y"] < H - 30:
        print(f"found '{found['text']}' score={found.get('score')} y={found['y']:.0f}", flush=True)
        cdp("Input.synthesizeTapGesture", x=found["x"], y=found["y"])
        print("real organic tap", flush=True)
        for w in range(18):
            time.sleep(1.2)
            try:
                now = (js("location.href") or "").lower()
                if is_target(now):
                    print("SUCCESS: organic landing →", now[:100], flush=True)
                    success = True
                    break
            except Exception:
                pass
            t = find_target_tab()
            if t:
                try:
                    ws.close()
                except Exception:
                    pass
                tab = t
                ws = websocket.create_connection(
                    tab["webSocketDebuggerUrl"], timeout=120,
                    suppress_origin=True, ping_interval=12, ping_timeout=8
                )
                cdp("Page.enable")
                cdp("Runtime.enable")
                cdp("Network.enable")
                print("SUCCESS: target tab", flush=True)
                success = True
                break
        if success:
            break
        print("  tap did not land – continue", flush=True)
        continue

    if found:
        smooth_scroll(int(found["y"] - H / 2), int(W / 2), int(H * 0.55))
    else:
        if maxY > 0 and scrollY >= maxY - 40:
            stale_bottom += 1
            if stale_bottom >= 2:
                print("  end of SERP page 1", flush=True)
                break
            smooth_scroll(-int(H * 0.2), int(W / 2), int(H * 0.5))
        else:
            stale_bottom = 0
        smooth_scroll(int(H * 0.38), int(W / 2), int(H * 0.62))

if not success:
    print("KEYWORD_MISS", flush=True)
    save_fail_debug("domain not found or tap failed on page 1")
    ws.close()
    sys.exit(1)

# ---- engagement (no screenshots on success) ----
NUM_PAGES = random.randint(4, 6)
MIN_DWELL, MAX_DWELL = 55, 110
print("\n=== ENGAGEMENT (no success screenshots) ===", flush=True)


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
print("starting on:", js("location.href"), flush=True)
for page_num in range(1, NUM_PAGES + 1):
    print(f"\n===== PAGE {page_num}/{NUM_PAGES} =====", flush=True)
    dwell = random.randint(MIN_DWELL, MAX_DWELL)
    print(f"  dwell ~{dwell}s", flush=True)
    smooth_scroll_random(dwell)
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
print("visited:", list(visited), flush=True)
ws.close()
print("DONE", flush=True)
sys.exit(0)
PY
}

# ===================== MAIN =====================
log "waiting for first boot"
wait_for_boot
if ensure_root; then HAVE_ROOT=1; fi
settle_device
pick_android_device
dump_identity

if [[ "$HAVE_ROOT" == "1" ]]; then
  write_device_identity
  log "rebooting so identity props load"
  adb reboot
  wait_for_boot
  if ensure_root; then HAVE_ROOT=1; else HAVE_ROOT=0; fi
  settle_device
  dump_identity
else
  log "skipping /data/local.prop (no root)"
fi

resolve_chrome
skip_chrome_welcome

open_url "$TARGET_URL"
sleep 6
dismiss_chrome_sheets
# no home screenshot on success path

install_websocket || {
  log "Cannot install websocket-client – aborting"
  screenshot_fail "FAIL-websocket.png"
  exit 1
}

HIT=0
for kw in "${KW_ARR[@]}"; do
  log "========== keyword attempt: $kw =========="
  if try_keyword "$kw"; then
    HIT=1
    log "SUCCESS with keyword: $kw as $MARKETNAME"
    break
  else
    log "Miss for keyword: $kw – trying next immediately"
  fi
done

if [[ "$HIT" == "1" ]]; then
  log "SUCCESS – $MARKETNAME (no success screenshots saved)"
  log "done"
  # keep only identity.txt from success runs
  ls -la "$ARTIFACTS" || true
  exit 0
fi

log "ALL keywords missed on page 1 – see FAIL-serp-*.json/txt/png in artifacts"
screenshot_fail "FAIL-all-keywords.png"
exit 0
