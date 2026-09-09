const test = require("node:test");
const assert = require("node:assert/strict");
const { normalizePushPlatform } = require("./notificationContract");

test("normalizePushPlatform preserves supported iOS platform", () => {
  assert.equal(normalizePushPlatform("ios"), "ios");
  assert.equal(normalizePushPlatform(" IOS "), "ios");
});

test("normalizePushPlatform recognizes Android registrations", () => {
  assert.equal(normalizePushPlatform("android"), "android");
  assert.equal(normalizePushPlatform(" ANDROID "), "android");
});

test("normalizePushPlatform fails closed for unsupported or missing values", () => {
  assert.equal(normalizePushPlatform("web"), "unknown");
  assert.equal(normalizePushPlatform(""), "unknown");
  assert.equal(normalizePushPlatform(null), "unknown");
  assert.equal(normalizePushPlatform(undefined), "unknown");
});
