import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { initializeApp, deleteApp } from "firebase/app";
import { connectAuthEmulator, getAuth, signInAnonymously } from "firebase/auth";
import { connectFunctionsEmulator, getFunctions, httpsCallable } from "firebase/functions";
import { deleteDoc, doc, getDoc, setDoc } from "firebase/firestore";
import { initializeTestEnvironment } from "@firebase/rules-unit-testing";

const PROJECT_ID = "demo-mypicsroom-security";
const CONSENT_DISCLOSURE_ID = "biometric-consent-v5";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
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

function identityEmbedding() {
  return [1, ...Array(511).fill(0)];
}

async function seedMatchableIdentity(db, uid) {
  const embedding = identityEmbedding();
  const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000);
  const templates = ["center", "sideA", "sideB"].map((pose, index) => ({
    id: `template-${index + 1}`,
    embedding,
    pose,
    quality: 1,
    createdAt: new Date(),
  }));

  await setDoc(doc(db, `users/${uid}`), {
    id: uid,
    displayName: "Member",
    hasFaceProfile: true,
  });
  await setDoc(doc(db, `users/${uid}/privacy/biometricConsent`), {
    userId: uid,
    policyVersion: 5,
    disclosureId: CONSENT_DISCLOSURE_ID,
    disclosureSHA256: CONSENT_DISCLOSURE_SHA256,
    acceptedAt: new Date(),
    withdrawnAt: null,
    expiredAt: null,
    expiresAt,
    jurisdictionCountry: "IN",
    jurisdictionSubdivision: "",
    age18Attested: true,
    noticeAcknowledged: true,
    ownFaceAttested: true,
  });
  await setDoc(doc(db, `users/${uid}/faceProfile/current`), {
    userId: uid,
    faceIdentityId: "stable-face",
    identityRevision: "v5:template-1|template-2|template-3",
    embedding,
    templates,
    version: 5,
    updatedAt: new Date(),
    expiresAt,
    consentPolicyVersion: 5,
    consentDisclosureId: CONSENT_DISCLOSURE_ID,
    consentDisclosureSHA256: CONSENT_DISCLOSURE_SHA256,
  });
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
  const listFaceProfiles = httpsCallable(functions, "listEventFaceProfiles");

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
    await seedMatchableIdentity(db, uid);
  });

  const firstResult = await listMembers({ eventId: "event-membership" });
  const first = firstResult.data.members.find((member) => member.userId === uid);
  assert.ok(first);
  assert.match(first.membershipId, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);

  const firstRoster = await listFaceProfiles({ eventId: "event-membership" });
  const firstFaceRow = firstRoster.data.participants.find((member) => member.userId === uid);
  assert.ok(firstFaceRow);
  assert.equal(firstRoster.data.callerMembershipId, first.membershipId);
  assert.equal(
    firstFaceRow.membershipId,
    first.membershipId,
    "biometric roster and member directory must describe the same participation generation"
  );

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

  const rejoinedRoster = await listFaceProfiles({ eventId: "event-membership" });
  const rejoinedFaceRow = rejoinedRoster.data.participants.find((member) => member.userId === uid);
  assert.ok(rejoinedFaceRow);
  assert.equal(rejoinedRoster.data.callerMembershipId, rejoined.membershipId);
  assert.equal(rejoinedFaceRow.membershipId, rejoined.membershipId);
  assert.notEqual(rejoinedFaceRow.membershipId, first.membershipId);

  // Source membership must remain available to Change 4 even when the caller is
  // temporarily not a match recipient. Sharing authorization is membership state,
  // not Face Setup state.
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await deleteDoc(doc(db, `users/${uid}/faceProfile/current`));
  });

  const sourceOnlyRoster = await listFaceProfiles({ eventId: "event-membership" });
  assert.equal(sourceOnlyRoster.data.callerMembershipId, rejoined.membershipId);
  assert.equal(
    sourceOnlyRoster.data.participants.some((member) => member.userId === uid),
    false,
    "caller without active Face Setup must not be emitted as a biometric recipient"
  );
});
