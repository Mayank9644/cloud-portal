/* Tests for assets/portal-common.js — run with: node test_portal_common.js */
"use strict";
const assert = require("assert");
const PortalCommon = require("./assets/portal-common.js");

let passed = 0;
function ok(name, fn) {
  fn();
  passed += 1;
  console.log("ok - " + name);
}

// URL allowlist
ok("accepts trycloudflare https", () => {
  assert.strictEqual(PortalCommon.isAllowedUrl("https://abc-def.trycloudflare.com/"), true);
  assert.strictEqual(PortalCommon.isAllowedUrl("https://abc-def.trycloudflare.com/health"), true);
});
ok("rejects javascript:", () => {
  assert.strictEqual(PortalCommon.isAllowedUrl("javascript:alert(1)"), false);
});
ok("rejects plain http to public hosts", () => {
  assert.strictEqual(PortalCommon.isAllowedUrl("http://abc.trycloudflare.com/"), false);
});
ok("rejects unknown domains", () => {
  assert.strictEqual(PortalCommon.isAllowedUrl("https://evil.com/phish"), false);
  assert.strictEqual(PortalCommon.isAllowedUrl("https://trycloudflare.com.evil.com/"), false);
});
ok("rejects garbage", () => {
  assert.strictEqual(PortalCommon.isAllowedUrl("not a url"), false);
  assert.strictEqual(PortalCommon.isAllowedUrl(""), false);
  assert.strictEqual(PortalCommon.isAllowedUrl(null), false);
});
ok("validateEndpointData drops bad urls, keeps good ones", () => {
  const out = PortalCommon.validateEndpointData({
    avatar_ops_url: "https://a-b.trycloudflare.com",
    nifty_analyzer_url: "javascript:alert(1)",
    updated_at: "x",
  });
  assert.strictEqual(out.avatar_ops_url, "https://a-b.trycloudflare.com");
  assert.strictEqual(out.nifty_analyzer_url, undefined);
  assert.strictEqual(PortalCommon.validateEndpointData({ avatar_ops_url: "https://evil.com" }), null);
});

// Freshness
ok("freshness: fresh vs stale", () => {
  const now = Date.parse("2026-10-20T12:00:00+05:30");
  const fresh = { updated_at: "2026-10-20 11:55:00 IST" }; // 5 min old
  const stale = { updated_at: "2026-10-20 11:00:00 IST" }; // 60 min old
  assert.strictEqual(PortalCommon.isStale(fresh, now), false);
  assert.strictEqual(PortalCommon.isStale(stale, now), true);
  assert.strictEqual(PortalCommon.isStale({}, now), true); // unknown = stale
  assert.strictEqual(PortalCommon.isStale({ updated_at: "garbage" }, now), true);
});

// UTF-8-safe base64 decode round-trip (audit L-1)
ok("base64 utf-8 decode round-trip", () => {
  const original = JSON.stringify({ host: "Samsung Galaxy Z Fold3 • 24/7 — ₹ test", n: 42 });
  const b64 = Buffer.from(original, "utf-8").toString("base64");
  assert.strictEqual(PortalCommon.decodeBase64Utf8(b64), original);
});

console.log("\n" + passed + " portal-common tests passed");
