const test = require("node:test");
const assert = require("node:assert/strict");
const { deduplicateMatchedPhotos } = require("../matchReadDedup");

function photo({
  id,
  installation = null,
  assetLocalId = "asset-1",
  capturedAtMillis = 1000,
  matchedAtMillis = 1100,
  updatedAtMillis = 1200,
  sourceUserId = "owner-1",
}) {
  return {
    id,
    sourceUserId,
    sourceInstallationId: installation,
    assetLocalId,
    capturedAtMillis,
    matchedAtMillis,
    updatedAtMillis,
  };
}

test("reinstall replay collapses exact owner asset capture tuple", () => {
  const before = photo({ id: "before", installation: "install-a", matchedAtMillis: 1100 });
  const after = photo({ id: "after", installation: "install-b", matchedAtMillis: 1300 });

  assert.deepEqual(deduplicateMatchedPhotos([before, after]), [after]);
});

test("newest match wins regardless of query order", () => {
  const old = photo({ id: "old", installation: "install-a", matchedAtMillis: 1100 });
  const latest = photo({ id: "latest", installation: "install-b", matchedAtMillis: 1400 });

  assert.deepEqual(deduplicateMatchedPhotos([latest, old]), [latest]);
  assert.deepEqual(deduplicateMatchedPhotos([old, latest]), [latest]);
});

test("different asset IDs are never collapsed", () => {
  const first = photo({ id: "first", installation: "install-a", assetLocalId: "asset-1" });
  const second = photo({ id: "second", installation: "install-b", assetLocalId: "asset-2" });

  assert.deepEqual(deduplicateMatchedPhotos([first, second]), [first, second]);
});

test("different capture instants are never collapsed", () => {
  const first = photo({ id: "first", installation: "install-a", capturedAtMillis: 1000 });
  const second = photo({ id: "second", installation: "install-b", capturedAtMillis: 1001 });

  assert.deepEqual(deduplicateMatchedPhotos([first, second]), [first, second]);
});

test("modern row wins exact time tie over legacy row", () => {
  const legacy = photo({ id: "legacy", installation: null, matchedAtMillis: 1300, updatedAtMillis: 1400 });
  const modern = photo({ id: "modern", installation: "install-a", matchedAtMillis: 1300, updatedAtMillis: 1400 });

  assert.deepEqual(deduplicateMatchedPhotos([legacy, modern]), [modern]);
});

test("malformed identity tuple is preserved rather than accidentally merged", () => {
  const first = photo({ id: "first", assetLocalId: "" });
  const second = photo({ id: "second", assetLocalId: "" });

  assert.deepEqual(deduplicateMatchedPhotos([first, second]), [first, second]);
});
