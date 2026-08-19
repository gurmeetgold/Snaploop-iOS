import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";

const expectedExports = new Set([
  "createEvent",
  "joinEvent",
  "resolveInvite",
  "updateEventManaged",
  "setEventStatus",
  "manageEventMember",
  "leaveEvent",
  "inviteByPhone",
  "listEventInvites",
  "nextPendingInvite",
  "declineEventInvite",
  "syncMyUserProfile",
  "updateDisplayName",
  "refreshMyFaceProfile",
  "eraseMyFaceProfile",
  "withdrawBiometricConsent",
  "deleteMyAccount",
  "setSharing",
  "publishMatch",
  "dismissAppearance",
  "cleanupRemovedMemberPhotoData",
  "syncEventRosterIdentities",
]);

function bootstrapExports() {
  const source = fs.readFileSync("functions/bootstrap.js", "utf8");
  return new Set([...source.matchAll(/exports\.([A-Za-z0-9_]+)\s*=/g)].map((match) => match[1]));
}

function swiftCallableNames(root) {
  const names = new Set();
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(full);
        continue;
      }
      if (!entry.name.endsWith(".swift")) continue;
      const source = fs.readFileSync(full, "utf8");
      for (const match of source.matchAll(/httpsCallable\(\s*"([^"]+)"\s*\)/g)) names.add(match[1]);
      for (const match of source.matchAll(/\bcall\(\s*"([^"]+)"\s*,\s*data:/g)) names.add(match[1]);
    }
  }
  return names;
}

test("production bootstrap exposes only the reviewed callable and trigger surface", () => {
  const actual = bootstrapExports();
  assert.deepEqual([...actual].sort(), [...expectedExports].sort());
});

test("every literal callable used by the iOS source is exported by production bootstrap", () => {
  const exported = bootstrapExports();
  const used = swiftCallableNames("Sources");
  const missing = [...used].filter((name) => !exported.has(name));
  assert.deepEqual(missing, [], `Missing callable exports: ${missing.join(", ")}`);
});
