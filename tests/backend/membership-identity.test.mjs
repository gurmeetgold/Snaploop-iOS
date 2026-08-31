import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { initializeApp, deleteApp } from "firebase/app";
import { connectAuthEmulator, getAuth, signInAnonymously } from "firebase/auth";
import { connectFunctionsEmulator, getFunctions, httpsCallable } from "firebase/functions";
import { deleteDoc, doc, getDoc, setDoc } from "firebase/firestore";
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

before(async () => {
  env = await initializeTestEnvironment({ projectId: PROJECT_ID });
  await env.clearFirestore();
});

after(async () => {
  if (app) await deleteApp(app);
  await env.cleanup();
});

test("membership generation is stable for one participation and rotates after leave/rejoin", async () => {
  app = initializeApp({
    projectId: PROJECT_ID,
    apiKey: "fake-api-key",
    authDomain: `${PROJECT_ID}.firebaseapp.com`,
  }, "membership-identity-client");

  const auth = getAuth(app);
  const authEndpoint = emulatorHostAndPort("FIREBASE_AUTH_EMULATOR_HOST", 9099);
  connectAuthEmulator(auth, `http://${authEndpoint.host}:${authEndpoint.port}`, { disableWarnings: true });
  const credential = await signInAnonymously(auth);
  const uid = credential.user.uid;

  const functions = getFunctions(app, "us-central1");
  const functionsEndpoint = emulatorHostAndPort("FUNCTIONS_EMULATOR_HOST", 5001);
  connectFunctionsEmulator(functions, functionsEndpoint.host, functionsEndpoint.port);
  const listMembers = httpsCallable(functions, "listEventMembers");

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, "events/event-membership"), {
      id: "event-membership",
      status: "active",
      memberCount: 1,
    });
    // Deliberately seed a pre-migration member without membershipId. The trusted
    // directory read must backfill it instead of trusting a client-supplied ID.
    await setDoc(doc(db, `events/event-membership/members/${uid}`), {
      userId: uid,
      role: "participant",
      sharingEnabled: true,
      joinedAt: new Date("2026-08-31T10:00:00Z"),
      faceTemplateVersion: 5,
    });
  });

  const firstResult = await listMembers({ eventId: "event-membership" });
  const first = firstResult.data.members.find((member) => member.userId === uid);
  assert.ok(first);
  assert.match(first.membershipId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);

  const secondResult = await listMembers({ eventId: "event-membership" });
  const second = secondResult.data.members.find((member) => member.userId === uid);
  assert.equal(second.membershipId, first.membershipId, "same participation must keep one generation");

  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const stored = await getDoc(doc(db, `events/event-membership/members/${uid}`));
    assert.equal(stored.data().membershipId, first.membershipId);

    // Simulate trusted leave + later rejoin. The old member document is gone,
    // therefore its generation must never be resurrected on the new document.
    await deleteDoc(doc(db, `events/event-membership/members/${uid}`));
    await setDoc(doc(db, `events/event-membership/members/${uid}`), {
      userId: uid,
      role: "participant",
      sharingEnabled: true,
      joinedAt: new Date("2026-08-31T11:00:00Z"),
      faceTemplateVersion: 5,
    });
  });

  const rejoinedResult = await listMembers({ eventId: "event-membership" });
  const rejoined = rejoinedResult.data.members.find((member) => member.userId === uid);
  assert.ok(rejoined);
  assert.match(rejoined.membershipId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
  assert.notEqual(rejoined.membershipId, first.membershipId, "rejoin must receive a fresh participation generation");
});
