function normalizedString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function comparableMillis(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : Number.NEGATIVE_INFINITY;
}

function presentationEquivalenceKey(photo) {
  const owner = normalizedString(photo && photo.sourceUserId);
  const asset = normalizedString(photo && photo.assetLocalId);
  const capturedAtMillis = Number(photo && photo.capturedAtMillis);
  if (!owner || !asset || !Number.isFinite(capturedAtMillis)) return null;
  return `${owner}|${asset}|${capturedAtMillis}`;
}

function shouldPrefer(candidate, current) {
  const candidateMatched = comparableMillis(candidate && candidate.matchedAtMillis);
  const currentMatched = comparableMillis(current && current.matchedAtMillis);
  if (candidateMatched !== currentMatched) return candidateMatched > currentMatched;

  const candidateUpdated = comparableMillis(candidate && candidate.updatedAtMillis);
  const currentUpdated = comparableMillis(current && current.updatedAtMillis);
  if (candidateUpdated !== currentUpdated) return candidateUpdated > currentUpdated;

  const candidateModern = !!normalizedString(candidate && candidate.sourceInstallationId);
  const currentModern = !!normalizedString(current && current.sourceInstallationId);
  if (candidateModern !== currentModern) return candidateModern;

  return String(candidate && candidate.id || "") > String(current && current.id || "");
}

/**
 * Read-only presentation reconciliation for reinstall/replay duplicates.
 *
 * Source-scoped Firestore rows remain untouched. When the same account publishes the exact same
 * local asset and capture instant under a rotated installation identity, only the newest row is
 * returned to clients. Different assets or capture instants are always preserved.
 */
function deduplicateMatchedPhotos(photos) {
  if (!Array.isArray(photos) || photos.length < 2) return Array.isArray(photos) ? photos.slice() : [];

  const winnerByKey = new Map();
  for (const photo of photos) {
    const key = presentationEquivalenceKey(photo);
    if (!key) continue;
    const current = winnerByKey.get(key);
    if (!current || shouldPrefer(photo, current)) winnerByKey.set(key, photo);
  }

  const emitted = new Set();
  const result = [];
  for (const photo of photos) {
    const key = presentationEquivalenceKey(photo);
    if (!key) {
      result.push(photo);
      continue;
    }
    if (emitted.has(key)) continue;
    emitted.add(key);
    result.push(winnerByKey.get(key));
  }
  return result;
}

module.exports = {
  deduplicateMatchedPhotos,
  presentationEquivalenceKey,
};
