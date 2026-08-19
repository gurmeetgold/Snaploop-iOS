import fs from "node:fs";
import { after, before, beforeEach, test } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
  updateDoc,
} from "firebase/firestore";
import {
  getBytes,
  ref as storageRef,
  uploadBytes,
} from "firebase/storage";

const PROJECT_ID = "demo-mypicsroom-security";
const BUCKET = `gs://${PROJECT_ID}.firebasestorage.app`;
let env;

const baseEvent = {
  id: "event-1",
  joinCode: "ABC123",
  inviteToken: "invite-token",
  creatorUserId: "alice",
  name: "Weekend",
  category: "trip",
  coverImagePath: null,
  locationName: null,
  startsAt: new Date("2026-08-18T00:00:00Z"),
  endsAt: new Date("2026-08-20T00:00:00Z"),
  status: "active",
  createdAt: new Date("2026-08-18T00:00:00Z"),
  updatedAt: new Date("2026-08-18T00:00:00Z"),
  memberCount: 2,
};

async function seedEvent({ photo = true } = {}) {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "events/event-1"), baseEvent);
    await setDoc(doc(db, "events/event-1/members/alice"), {
      userId: "alice",
      role: "organizer",
      sharingEnabled: true,
      joinedAt: new Date("2026-08-18T00:00:00Z"),
      faceTemplateVersion: 5,
    });
    await setDoc(doc(db, "events/event-1/members/bob"), {
      userId: "bob",
      role: "participant",
      sharingEnabled: true,
      joinedAt: new Date("2026-08-18T00:00:00Z"),
      faceTemplateVersion: 5,
    });
    if (photo) {
      await setDoc(doc(db, "events/event-1/photos/photo-1"), {
        id: "event-1:asset-1",
        eventId: "event-1",
        sourceUserId: "bob",
        assetLocalId: "asset-1",
        appearances: [{ participantUserId: "alice", confidence: 0.91, dismissedByUser: false }],
        matchedUserIds: ["alice"],
        capturedAt: new Date("2026-08-19T00:00:00Z"),
        matchedAt: new Date("2026-08-19T00:01:00Z"),
        thumbnailPath: "events/event-1/photos/bob/photo-1/thumbnail.jpg",
      });
    }
  });
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: fs.readFileSync("backend/firestore.rules", "utf8") },
    storage: { rules: fs.readFileSync("backend/storage.rules", "utf8") },
  });
});

after(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.clearStorage();
});

test("user identity is readable by self but cannot be forged client-side", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "users/alice"), {
      id: "alice",
      phoneNumber: "+14165550101",
      displayName: "Alice",
      hasFaceProfile: false,
      createdAt: new Date(),
    });
  });

  const alice = env.authenticatedContext("alice").firestore();
  const bob = env.authenticatedContext("bob").firestore();
  await assertSucceeds(getDoc(doc(alice, "users/alice")));
  await assertFails(getDoc(doc(bob, "users/alice")));
  await assertFails(updateDoc(doc(alice, "users/alice"), { phoneNumber: "+14165550999" }));
  await assertFails(setDoc(doc(alice, "users/alice"), { phoneNumber: "+14165550999" }));
});

test("member roles, sharing state and photo match metadata are server-owned", async () => {
  await seedEvent();
  const alice = env.authenticatedContext("alice").firestore();
  const bob = env.authenticatedContext("bob").firestore();

  await assertSucceeds(getDoc(doc(alice, "events/event-1")));
  await assertFails(updateDoc(doc(bob, "events/event-1/members/bob"), { sharingEnabled: false }));
  await assertFails(updateDoc(doc(alice, "events/event-1/members/bob"), { role: "admin" }));
  await assertFails(setDoc(doc(bob, "events/event-1/photos/forged"), {
    sourceUserId: "alice",
    matchedUserIds: ["alice"],
  }));
  await assertFails(updateDoc(doc(bob, "events/event-1/photos/photo-1"), {
    matchedUserIds: ["bob"],
  }));
});

test("outsiders cannot enumerate event data or roster", async () => {
  await seedEvent();
  const outsider = env.authenticatedContext("mallory").firestore();
  await assertFails(getDoc(doc(outsider, "events/event-1")));
  await assertFails(getDoc(doc(outsider, "events/event-1/members/alice")));
  await assertFails(getDoc(doc(outsider, "events/event-1/photos/photo-1")));
});

test("self face profile enrollment is allowed but direct biometric deletion is denied", async () => {
  const alice = env.authenticatedContext("alice").firestore();
  const bob = env.authenticatedContext("bob").firestore();
  const profile = {
    userId: "alice",
    embedding: [0.1, 0.2],
    templates: [],
    version: 5,
    updatedAt: new Date(),
  };

  await assertSucceeds(setDoc(doc(alice, "users/alice/faceProfile/current"), profile));
  await assertFails(setDoc(doc(bob, "users/alice/faceProfile/current"), profile));
  await assertFails(deleteDoc(doc(alice, "users/alice/faceProfile/current")));
});

test("biometric consent withdrawal cannot be forged with a direct client write", async () => {
  const alice = env.authenticatedContext("alice").firestore();
  const consentRef = doc(alice, "users/alice/privacy/biometricConsent");

  await assertSucceeds(setDoc(consentRef, {
    userId: "alice",
    policyVersion: 1,
    acceptedAt: new Date(),
    withdrawnAt: null,
  }));
  await assertFails(updateDoc(consentRef, { withdrawnAt: new Date() }));
});

test("organizer may only directly end an active event", async () => {
  await seedEvent({ photo: false });
  const alice = env.authenticatedContext("alice").firestore();
  const event = doc(alice, "events/event-1");

  await assertFails(updateDoc(event, { name: "Forged direct edit" }));
  await assertFails(updateDoc(event, { status: "deletedByOrganizer", updatedAt: new Date() }));
  await assertFails(updateDoc(event, { status: "not-a-real-status", updatedAt: new Date() }));
  await assertSucceeds(updateDoc(event, { status: "endedByOrganizer", updatedAt: new Date() }));
  await assertFails(updateDoc(event, { status: "active", updatedAt: new Date() }));
});

test("thumbnail access requires event membership and trusted backing photo metadata", async () => {
  await seedEvent();
  const bobStorage = env.authenticatedContext("bob").storage(BUCKET);
  const aliceStorage = env.authenticatedContext("alice").storage(BUCKET);
  const outsiderStorage = env.authenticatedContext("mallory").storage(BUCKET);
  const path = "events/event-1/photos/bob/photo-1/thumbnail.jpg";
  const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);

  await assertSucceeds(uploadBytes(storageRef(bobStorage, path), bytes, { contentType: "image/jpeg" }));
  await assertSucceeds(getBytes(storageRef(aliceStorage, path)));
  await assertFails(getBytes(storageRef(outsiderStorage, path)));

  // Sharing-off and member-removal callables delete the trusted backing photo
  // metadata. The object becomes unreadable immediately even if blob cleanup is
  // retried asynchronously.
  await env.withSecurityRulesDisabled(async (ctx) => {
    await deleteDoc(doc(ctx.firestore(), "events/event-1/photos/photo-1"));
  });
  await assertFails(getBytes(storageRef(aliceStorage, path)));
});

test("thumbnail upload cannot target another member namespace", async () => {
  await seedEvent({ photo: false });
  const aliceStorage = env.authenticatedContext("alice").storage(BUCKET);
  const path = "events/event-1/photos/bob/photo-1/thumbnail.jpg";
  await assertFails(uploadBytes(
    storageRef(aliceStorage, path),
    new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
    { contentType: "image/jpeg" }
  ));
});
