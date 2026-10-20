/* Fincept Cloud Host — shared portal logic (audit L-2).
 *
 * ONE implementation used by index.html, avatar-ops/index.html and
 * nifty-analyzer/index.html.
 *
 * Security model (audit C2, H-8, M-4, M-5, H-6):
 * - Endpoint resolution order: GitHub Contents API -> raw.githubusercontent
 *   -> ./endpoints.json. ntfy is REMOVED as a trusted source: public ntfy
 *   topics are world-writable, so anyone could inject fake endpoints and
 *   redirect portal visitors (audit C2). GitHub is the source of truth.
 * - Every URL is validated against an allowlist before ANY use
 *   (https: only, hostname *.trycloudflare.com OR the configured domain
 *   OR localhost).
 * - Freshness: updated_at older than STALE_MS renders a STALE warning and
 *   the data is not treated as live.
 * - no-cors opaque responses mean "unknown", NEVER "online".
 * - Callers must render endpoint data with textContent / validated href
 *   only — never innerHTML interpolation.
 */
(function (global) {
  "use strict";

  var STALE_MS = 10 * 60 * 1000; // 10 minutes
  // Set window.PORTAL_CONFIGURED_DOMAIN before loading, or edit here once a
  // named tunnel + own domain is activated (docs/NAMED-TUNNEL.md).
  var CONFIGURED_DOMAIN = (global.PORTAL_CONFIGURED_DOMAIN || "").toLowerCase();

  var GITHUB_CONTENTS_URL =
    "https://api.github.com/repos/Mayank9644/cloud-portal/contents/endpoints.json";
  var RAW_URL =
    "https://raw.githubusercontent.com/Mayank9644/cloud-portal/main/endpoints.json";

  /* UTF-8-safe base64 decode (audit L-1: no escape()/unescape()). */
  function decodeBase64Utf8(b64) {
    var clean = String(b64).replace(/\s/g, "");
    var binary = atob(clean);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder("utf-8").decode(bytes);
  }

  function isAllowedUrl(value) {
    if (!value || typeof value !== "string") return false;
    var u;
    try {
      u = new URL(value);
    } catch (e) {
      return false;
    }
    if (u.protocol !== "https:" && !(u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1"))) {
      // https: required except loopback for local dev
      if (u.protocol !== "https:") return false;
    }
    var host = u.hostname.toLowerCase();
    if (host === "localhost" || host === "127.0.0.1") return u.protocol === "http:" || u.protocol === "https:";
    if (host.endsWith(".trycloudflare.com")) return u.protocol === "https:";
    if (CONFIGURED_DOMAIN && (host === CONFIGURED_DOMAIN || host.endsWith("." + CONFIGURED_DOMAIN))) {
      return u.protocol === "https:";
    }
    return false;
  }

  function validateEndpointData(data) {
    if (!data || typeof data !== "object") return null;
    var out = {};
    if (isAllowedUrl(data.avatar_ops_url)) out.avatar_ops_url = data.avatar_ops_url;
    if (isAllowedUrl(data.nifty_analyzer_url)) out.nifty_analyzer_url = data.nifty_analyzer_url;
    if (isAllowedUrl(data.host_daemon_url)) out.host_daemon_url = data.host_daemon_url;
    if (typeof data.host === "string") out.host = data.host;
    if (typeof data.updated_at === "string") out.updated_at = data.updated_at;
    if (!out.avatar_ops_url && !out.nifty_analyzer_url) return null;
    return out;
  }

  /* Parse "2026-10-19 20:49:28 IST" and ISO strings alike. Returns ms or NaN. */
  function parseUpdatedAt(value) {
    if (!value) return NaN;
    var s = String(value).trim();
    var iso = s.replace(" IST", "+05:30").replace(" ", "T");
    var t = Date.parse(iso);
    if (!isNaN(t)) return t;
    return Date.parse(s);
  }

  function isStale(data, nowMs) {
    var t = parseUpdatedAt(data && data.updated_at);
    if (isNaN(t)) return true; // unknown freshness = do not trust as live
    var now = typeof nowMs === "number" ? nowMs : Date.now();
    return now - t > STALE_MS;
  }

  async function fetchJson(url, timeoutMs) {
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, timeoutMs || 8000);
    try {
      var res = await fetch(url, { cache: "no-store", signal: ctrl.signal });
      if (!res.ok) throw new Error("HTTP " + res.status);
      return await res.json();
    } finally {
      clearTimeout(timer);
    }
  }

  /* Resolution: GitHub Contents API -> raw file -> local ./endpoints.json.
   * Path prefix lets sub-pages point at ../endpoints.json. */
  async function resolveEndpoints(localPath) {
    // 1. GitHub Contents API (bypasses raw CDN cache)
    try {
      var g = await fetchJson(GITHUB_CONTENTS_URL, 8000);
      if (g && g.content) {
        var data = validateEndpointData(JSON.parse(decodeBase64Utf8(g.content)));
        if (data) return data;
      }
    } catch (e) { /* fall through */ }
    // 2. Raw file
    try {
      var raw = validateEndpointData(await fetchJson(RAW_URL, 8000));
      if (raw) return raw;
    } catch (e) { /* fall through */ }
    // 3. Local copy shipped with the portal
    try {
      var local = validateEndpointData(await fetchJson(localPath || "./endpoints.json", 5000));
      if (local) return local;
    } catch (e) { /* fall through */ }
    return null;
  }

  /* Probe a tunnel URL. Returns "online" | "unknown" | "offline".
   * An opaque no-cors response proves only that *something* answered at the
   * edge (possibly a Cloudflare error page) -> "unknown", never "online". */
  async function checkTunnelHealth(url, timeoutMs) {
    if (!isAllowedUrl(url)) return "offline";
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, timeoutMs || 7000);
    try {
      var res = await fetch(url, { cache: "no-store", signal: ctrl.signal });
      clearTimeout(timer);
      if (res.type === "opaque") return "unknown";
      return res.status < 500 ? "online" : "offline";
    } catch (e) {
      clearTimeout(timer);
      // CORS failures land here too; try no-cors to distinguish dead vs blocked.
      try {
        var r2 = await fetch(url, { mode: "no-cors", cache: "no-store" });
        if (r2 && r2.type === "opaque") return "unknown";
        return "unknown";
      } catch (e2) {
        return "offline";
      }
    }
  }

  var api = {
    STALE_MS: STALE_MS,
    decodeBase64Utf8: decodeBase64Utf8,
    isAllowedUrl: isAllowedUrl,
    validateEndpointData: validateEndpointData,
    parseUpdatedAt: parseUpdatedAt,
    isStale: isStale,
    resolveEndpoints: resolveEndpoints,
    checkTunnelHealth: checkTunnelHealth,
  };

  if (typeof module !== "undefined" && module.exports) module.exports = api;
  global.PortalCommon = api;
})(typeof window !== "undefined" ? window : globalThis);
