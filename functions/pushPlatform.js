"use strict";

const SUPPORTED_PUSH_PLATFORMS = new Set(["ios", "android"]);

/**
 * Preserve known mobile platforms for token metadata while keeping the existing
 * safe fallback for malformed, web, or future clients that have not been
 * explicitly supported yet.
 */
function normalizePushPlatform(value) {
  if (typeof value !== "string") return "unknown";
  const normalized = value.trim().toLowerCase();
  return SUPPORTED_PUSH_PLATFORMS.has(normalized) ? normalized : "unknown";
}

module.exports = { normalizePushPlatform };
