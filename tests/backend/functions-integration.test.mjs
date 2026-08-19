import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { initializeApp, deleteApp } from "firebase/app";
import {
  connectAuthEmulator,
  getAuth,
  signInAnonymously,
} from "firebase/auth";
import {
  connectFunctionsEmulator,
  getFunctions,
  httpsCallable,
} from "firebase/functions";
import {
  doc,
  getDoc,
  setDoc,
} from "firebase/firestore";
import {
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";

const PROJECT_ID = "demo-mypicsroom-security";
const APPS = [];
let env;
let appCounter = 0;

function emulatorHostAndPort(variable, fallbackPort) {
  const value = process.env[variable];
  if (!value) return { host: "127.0.0.1", port: fallbackPort };
  const lastColon = value.lastIndexOf(":");
  return {
    host: value.slice(0, lastColon),
    port: Number(value.slice(lastColon + 1)),
  };
}

async function signedInClient() {
  appCounter += 1;
  const app = initializeApp({
    projectId: PROJECT_ID,
    apiKey: "fake-api-key",
    authDomain: `${PROJECT_ID}.firebaseapp.com`,
  }, `test-client-${appCounter}`);
  APPS.push(app);

  const auth = getAuth(app);
  const authEndpoint = emulatorHostAndPort("FIREBASE_AUTH_EMULATOR_HOST", 9099);
  connectAuthEmulator(auth, `http://${authEndpoint.host}:${authEndpoint.port}`, { disableWarnings: true });
  const credential = await signInAnonymously(auth);

  const functions = getFunctions(app, "us-central1");
  const functionsEndpoint = emulatorHostAndPort("FUNCTIONS_EMULATOR_HOST", 5001);
  connectFunctionsEmulator(functions, functionsEndpoint.host, functionsEndpoint.port);

  return { uid: credential.user.uid, functions };
}

async function seed(callback) {
  await env.withSecurityRulesDisabled(async (context) => {
    await callback(context.firestore());
  });
}

async function seedMemberEvent({ organizerUid, participantUid, includePhoto = false }) {
  await seed(async (db) => {
    await setDoc(doc(db, "events/event-1"), {
      id: "event-1",
      joinCode: "ABC123",
      inviteToken: "invite-token",
      creatorUserId: organizerUid,
      name: "Weekend",
      category: "trip",
      coverImagePath: null,
      locationName: null,
      startsAt: new Date("2026-08-18T00:00:00Z"),
      endsAt: new Date("2026-08-20T00:00:00Z"),
      status: "active",
      createdAt: new Date("2026-08-18T00:00:00Z"),
      updatedAt: new Date("2026-08-18T00:00:00Z"),
      memberCount: participantUid ? 2 : 1,
    });
    await setDoc(doc(db, `events/event-1/members/${organizerUid}`), {
      userId: organizerUid,
      role: "organizer",
      sharingEnabled: true,
      joinedAt: new Date(),
      faceTemplateVersion: 5,
    });
    await setDoc(doc(db, `users/${organizerUid}/eventRefs/event-1`), {
      eventId: "event-1",
      role: "organizer",
      joinedAt: new Date(),
    });

    if (participantUid) {
      await setDoc(doc(db, `events/event-1/members/${participantUid}`), {
        userId: participantUid,
        role: "participant",
        sharingEnabled: true,
        joinedAt: new Date(),
        faceTemplateVersion: 5,
      });
      await setDoc(doc(db, `users/${participantUid}/eventRefs/event-1`), {
        eventId: "event-1",
        role: "participant",
        joinedAt: new Date(),
      });
    }

    if (includePhoto && participantUid) {
      await setDoc(doc(db, "events/event-1/photos/photo-1"), {
        id: "event-1:asset-1",
        eventId: "event-1",
        sourceUserId: participantUid,
        assetLocalId: "asset-1",
        appearances: [{ participantUserId: organizerUid, confidence: 0.91, dismissedByUser: false }],
        matchedUserIds: [organizerUid],
        capturedAt: new Date("2026-08-19T00:00:00Z"),
        matchedAt: new Date("2026-08-19T00:01:00Z"),
        thumbnailPath: `events/event-1/photos/${participantUid}/photo-1/thumbnail.jpg`,
      });
    }
  });
}

before(async () => {
  env = await initializeTestEnvironment({ projectId: PROJECT_ID });
});

beforeEach(async () => {
  await env.clearFirestore();
});

after(async () => {
  await Promise.all(APPS.map((app) => deleteApp(app)));
  await env.cleanup();
});

test("setEventStatus enforces organizer authorization and legal transitions", async () => {
  const organizer = await signedInClient();
  const participant = await signedInClient();
  await seedMemberEvent({ organizerUid: organizer.uid, participantUid: participant.uid });

  const organizerSetStatus = httpsCallable(organizer.functions, "setEventStatus");
  const participantSetStatus = httpsCallable(participant.functions, "setEventStatus");

  await assert.rejects(() => participantSetStatus({ eventId: "event-1", status: "endedByOrganizer" }));
  await organizerSetStatus({ eventId: "event-1", status: "endedByOrganizer" });

  await env.withSecurityRulesDisabled(async (context) => {
    const snap = await getDoc(doc(context.firestore(), "events/event-1"));
    assert.equal(snap.data().status, "endedByOrganizer");
  });

  await assert.rejects(() => organizerSetStatus({ eventId: "event-1", status: "expired" }));
  await organizerSetStatus({ eventId: "event-1", status: "active" });
});

test("setSharing can only change the caller and sharing-off removes authored metadata", async () => {
  const organizer = await signedInClient();
  const participant = await signedInClient();
  await seedMemberEvent({ organizerUid: organizer.uid, participantUid: participant.uid, includePhoto: true });

  const participantSetSharing = httpsCallable(participant.functions, "setSharing");
  await assert.rejects(() => participantSetSharing({
    eventId: "event-1",
    userId: organizer.uid,
    enabled: false,
  }));

  await participantSetSharing({
    eventId: "event-1",
    userId: participant.uid,
    enabled: false,
  });

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const member = await getDoc(doc(db, `events/event-1/members/${participant.uid}`));
    const photo = await getDoc(doc(db, "events/event-1/photos/photo-1"));
    assert.equal(member.data().sharingEnabled, false);
    assert.equal(photo.exists(), false);
  });
});

test("face erasure removes profile, event snapshot, and appearance metadata", async () => {
  const user = await signedInClient();
  const other = await signedInClient();
  await seedMemberEvent({ organizerUid: other.uid, participantUid: user.uid });

  await seed(async (db) => {
    await setDoc(doc(db, `users/${user.uid}`), {
      id: user.uid,
      phoneNumber: "+14165550100",
      displayName: "User",
      hasFaceProfile: true,
      createdAt: new Date(),
    });
    await setDoc(doc(db, `users/${user.uid}/faceProfile/current`), {
      userId: user.uid,
      embedding: [0.1, 0.2],
      templates: [],
      version: 5,
      updatedAt: new Date(),
    });
    await setDoc(doc(db, `events/event-1/participants/${user.uid}`), {
      userId: user.uid,
      displayName: "User",
      faceEmbedding: [0.1, 0.2],
      faceTemplates: [],
      faceProfileVersion: 5,
      joinedAt: new Date(),
    });
    await setDoc(doc(db, "events/event-1/photos/other-photo"), {
      id: "event-1:other-asset",
      eventId: "event-1",
      sourceUserId: other.uid,
      assetLocalId: "other-asset",
      appearances: [{ participantUserId: user.uid, confidence: 0.88, dismissedByUser: false }],
      matchedUserIds: [user.uid],
      capturedAt: new Date(),
      matchedAt: new Date(),
      thumbnailPath: `events/event-1/photos/${other.uid}/other-photo/thumbnail.jpg`,
    });
  });

  await httpsCallable(user.functions, "eraseMyFaceProfile")({ userId: user.uid });

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    assert.equal((await getDoc(doc(db, `users/${user.uid}/faceProfile/current`))).exists(), false);
    assert.equal((await getDoc(doc(db, `events/event-1/participants/${user.uid}`))).exists(), false);
    const photo = await getDoc(doc(db, "events/event-1/photos/other-photo"));
    assert.deepEqual(photo.data().matchedUserIds, []);
    assert.deepEqual(photo.data().appearances, []);
    const userDoc = await getDoc(doc(db, `users/${user.uid}`));
    assert.equal(userDoc.data().hasFaceProfile, false);
  });
});

test("account deletion removes a non-organizer membership and authored shared metadata", async () => {
  const organizer = await signedInClient();
  const user = await signedInClient();
  await seedMemberEvent({ organizerUid: organizer.uid, participantUid: user.uid, includePhoto: true });

  await seed(async (db) => {
    await setDoc(doc(db, `users/${user.uid}`), {
      id: user.uid,
      phoneNumber: "+14165550101",
      displayName: "Delete Me",
      hasFaceProfile: false,
      createdAt: new Date(),
    });
    await setDoc(doc(db, `events/event-1/participants/${user.uid}`), {
      userId: user.uid,
      displayName: "Delete Me",
      faceEmbedding: [0.1, 0.2],
      faceTemplates: [],
      faceProfileVersion: 5,
      joinedAt: new Date(),
    });
  });

  await httpsCallable(user.functions, "deleteMyAccount")({ userId: user.uid });

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    assert.equal((await getDoc(doc(db, `users/${user.uid}`))).exists(), false);
    assert.equal((await getDoc(doc(db, `events/event-1/members/${user.uid}`))).exists(), false);
    assert.equal((await getDoc(doc(db, `events/event-1/participants/${user.uid}`))).exists(), false);
    assert.equal((await getDoc(doc(db, "events/event-1/photos/photo-1"))).exists(), false);
  });
});

test("forged user identity and forged photo identity are rejected before persistence", async () => {
  const user = await signedInClient();
  const other = await signedInClient();
  await seedMemberEvent({ organizerUid: other.uid, participantUid: user.uid });

  await assert.rejects(() => httpsCallable(user.functions, "syncMyUserProfile")({
    userId: other.uid,
    displayName: "Forged",
  }));

  await assert.rejects(() => httpsCallable(user.functions, "publishMatch")({
    id: "event-1:not-the-asset",
    eventId: "event-1",
    assetLocalId: "asset-1",
    appearances: [],
    capturedAtMillis: Date.parse("2026-08-19T00:00:00Z"),
    matchedAtMillis: Date.now(),
    thumbnailPath: `events/event-1/photos/${user.uid}/bogus/thumbnail.jpg`,
  }));
});
