function normalizePushPlatform(value) {
  const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
  return normalized === "ios" || normalized === "android" ? normalized : "unknown";
}

module.exports = { normalizePushPlatform };
