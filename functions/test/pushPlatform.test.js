"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { normalizePushPlatform } = require("../pushPlatform");

test("preserves supported iOS and Android platforms", () => {
  assert.equal(normalizePushPlatform("ios"), "ios");
  assert.equal(normalizePushPlatform("android"), "android");
});

test("normalizes benign casing and whitespace", () => {
  assert.equal(normalizePushPlatform(" IOS "), "ios");
  assert.equal(normalizePushPlatform(" Android "), "android");
});

test("falls back to unknown for unsupported or malformed values", () => {
  assert.equal(normalizePushPlatform("web"), "unknown");
  assert.equal(normalizePushPlatform(""), "unknown");
  assert.equal(normalizePushPlatform(null), "unknown");
  assert.equal(normalizePushPlatform(undefined), "unknown");
});
