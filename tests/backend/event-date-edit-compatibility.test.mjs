import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { initializeApp, deleteApp } from "firebase/app";
import { connectAuthEmulator, getAuth, signInAnonymously } from "firebase/auth";
import { connectFunctionsEmulator, getFunctions, httpsCallable } from "firebase/functions";
import { doc, getDoc, setDoc } from "firebase/firestore";
import { initializeTestEnvironment } from "@firebase/rules-unit-testing";

const PROJECT_ID = "demo-mypicsroom-security";
let env;
let app;

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
  app = initializeApp({
    projectId: PROJECT_ID,
    apiKey: "fake-api-key",
    authDomain: `${PROJECT_ID}.firebaseapp.com`,
  }, `event-date-client-${Date.now()}`);

  const auth = getAuth(app);
  const authEndpoint = emulatorHostAndPort("FIREBASE_AUTH_EMULATOR_HOST", 9099);
  connectAuthEmulator(auth, `http://${authEndpoint.host}:${authEndpoint.port}`, { disableWarnings: true });
  const credential = await signInAnonymously(auth);

  const functions = getFunctions(app, "us-central1");
  const functionsEndpoint = emulatorHostAndPort("FUNCTIONS_EMULATOR_HOST", 5001);
  connectFunctionsEmulator(functions, functionsEndpoint.host, functionsEndpoint.port);
  return { uid: credential.user.uid, functions };
}

async function seedOrganizerEvent(uid, { startsAt, endsAt, name = "Legacy Event" }) {
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "events/event-dates"), {
      id: "event-dates",
      joinCode: "ABC234",
      inviteToken: "ABCDEFGHIJKLMNOPQRSTUV",
      creatorUserId: uid,
      name,
      category: "trip",
      startsAt,
      endsAt,
      status: "active",
      createdAt: startsAt,
      updatedAt: startsAt,
      memberCount: 1,
    });
    await setDoc(doc(db, `events/event-dates/members/${uid}`), {
      userId: uid,
      role: "organizer",
      sharingEnabled: true,
      joinedAt: startsAt,
      faceTemplateVersion: 5,
    });
  });
}

async function storedEvent() {
  let snapshot;
  await env.withSecurityRulesDisabled(async (context) => {
    snapshot = await getDoc(doc(context.firestore(), "events/event-dates"));
  });
  return snapshot;
}

before(async () => {
  env = await initializeTestEnvironment({ projectId: PROJECT_ID });
});

beforeEach(async () => {
  await env.clearFirestore();
  if (app) {
    await deleteApp(app);
    app = null;
  }
});

after(async () => {
  if (app) await deleteApp(app);
  await env.cleanup();
});

test("rename-only legacy Event preserves its original timestamps exactly", async () => {
  const client = await signedInClient();
  const startsAt = new Date("2025-01-10T15:37:12.345Z");
  const endsAt = new Date("2025-01-12T09:11:22.678Z");
  await seedOrganizerEvent(client.uid, { startsAt, endsAt });

  const update = httpsCallable(client.functions, "updateEventManaged");
  await update({
    eventId: "event-dates",
    name: "Renamed Only",
    // Simulate a pre-Change-3 client, which always resent unchanged date fields.
    startsAtMillis: startsAt.getTime(),
    endsAtMillis: endsAt.getTime(),
    startsAtOffsetMinutes: 0,
    endsAtOffsetMinutes: 0,
    nowOffsetMinutes: 0,
  });

  const snapshot = await storedEvent();
  const data = snapshot.data();
  assert.equal(data.name, "Renamed Only");
  assert.equal(data.startsAt.toMillis(), startsAt.getTime());
  assert.equal(data.endsAt.toMillis(), endsAt.getTime());
  assert.equal(data.photoWindowVersion, undefined);
  assert.equal(data.photoWindowTimeZoneId, undefined);
});

test("intentional v1 date edit persists canonical timezone and civil-day ordinals", async () => {
  const client = await signedInClient();
  const now = new Date();
  const todayUTC = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const oldStart = new Date(todayUTC - 24 * 60 * 60 * 1000);
  const oldEnd = new Date(todayUTC - 1);
  await seedOrganizerEvent(client.uid, { startsAt: oldStart, endsAt: oldEnd, name: "Current Event" });

  const newStart = todayUTC;
  const newEnd = todayUTC + (2 * 24 * 60 * 60 * 1000) - 1;
  const update = httpsCallable(client.functions, "updateEventManaged");
  await update({
    eventId: "event-dates",
    startsAtMillis: newStart,
    endsAtMillis: newEnd,
    startsAtOffsetMinutes: 0,
    endsAtOffsetMinutes: 0,
    nowOffsetMinutes: 0,
    photoWindowVersion: 1,
    photoWindowTimeZoneId: "UTC",
  });

  const snapshot = await storedEvent();
  const data = snapshot.data();
  assert.equal(data.startsAt.toMillis(), newStart);
  assert.equal(data.endsAt.toMillis(), newEnd);
  assert.equal(data.photoWindowVersion, 1);
  assert.equal(data.photoWindowTimeZoneId, "UTC");
  assert.equal(data.photoWindowEndDayNumber - data.photoWindowStartDayNumber, 1);
});

test("resolveInvite carries canonical Event photo-window metadata before join", async () => {
  const client = await signedInClient();
  const startsAt = new Date("2026-08-16T04:00:00.000Z");
  const endsAt = new Date("2026-08-18T03:59:59.999Z");
  const token = "ABCDEFGHIJKLMNOPQRSTUV";

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "events/canonical-invite"), {
      id: "canonical-invite",
      joinCode: "XYZ234",
      inviteToken: token,
      creatorUserId: "organizer",
      name: "Toronto Weekend",
      category: "trip",
      startsAt,
      endsAt,
      photoWindowVersion: 1,
      photoWindowTimeZoneId: "America/Toronto",
      photoWindowStartDayNumber: 20681,
      photoWindowEndDayNumber: 20682,
      status: "active",
      createdAt: startsAt,
      updatedAt: startsAt,
      memberCount: 1,
    });
    await setDoc(doc(db, `inviteTokens/${token}`), {
      eventId: "canonical-invite",
      createdAt: startsAt,
    });
  });

  const resolve = httpsCallable(client.functions, "resolveInvite");
  const result = await resolve({ inviteToken: token });
  const event = result.data.event;

  assert.equal(event.id, "canonical-invite");
  assert.equal(event.startsAtMillis, startsAt.getTime());
  assert.equal(event.endsAtMillis, endsAt.getTime());
  assert.equal(event.photoWindowVersion, 1);
  assert.equal(event.photoWindowTimeZoneId, "America/Toronto");
  assert.equal(event.photoWindowStartDayNumber, 20681);
  assert.equal(event.photoWindowEndDayNumber, 20682);
});
