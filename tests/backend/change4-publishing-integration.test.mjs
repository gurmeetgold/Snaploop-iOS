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
import { initializeTestEnvironment } from "@firebase/rules-unit-testing";

const PROJECT_ID = "demo-mypicsroom-security";
const CONSENT_DISCLOSURE_SHA256 = "2b78a5de4ced7219953cf4c3b62e07dce41392b0090f7c07c3fcb307411bc30f";
const SOURCE_INSTALLATION_ID = "a".repeat(64);
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
  }, `change4-publish-client-${appCounter}`);
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

function profileRevision() {
  return "v5:center-template|side-template";
}

async function seedPublishedMatch({
  sourceUid,
  recipientUid,
  recipientMembershipId = "recipient-membership",
}) {
  const now = Date.now();
  const startsAt = new Date(now - (24 * 60 * 60 * 1000));
  const endsAt = new Date(now + (24 * 60 * 60 * 1000));
  const capturedAt = new Date(now - 60_000);
  const sourceMembershipId = "source-membership";
  const faceIdentityId = "recipient-face";
  const revision = profileRevision();
  const matchId = `event-1:${SOURCE_INSTALLATION_ID}:asset-1`;
  const photoId = Buffer.from(matchId, "utf8").toString("base64url");
  const thumbnailPath = `events/event-1/photos/${sourceUid}/${photoId}/thumbnail.jpg`;

  await seed(async (db) => {
    await setDoc(doc(db, "events/event-1"), {
      id: "event-1",
      creatorUserId: sourceUid,
      name: "Event",
      category: "trip",
      startsAt,
      endsAt,
      status: "active",
      memberCount: 2,
      createdAt: startsAt,
      updatedAt: new Date(now),
    });
    await setDoc(doc(db, `events/event-1/members/${sourceUid}`), {
      userId: sourceUid,
      membershipId: sourceMembershipId,
      role: "organizer",
      sharingEnabled: true,
      joinedAt: startsAt,
    });
    await setDoc(doc(db, `events/event-1/members/${recipientUid}`), {
      userId: recipientUid,
      membershipId: recipientMembershipId,
      role: "participant",
      sharingEnabled: true,
      joinedAt: startsAt,
    });
    await setDoc(doc(db, `users/${recipientUid}/faceProfile/current`), {
      userId: recipientUid,
      faceIdentityId,
      version: 5,
      consentPolicyVersion: 5,
      consentDisclosureId: "biometric-consent-v5",
      consentDisclosureSHA256: CONSENT_DISCLOSURE_SHA256,
      expiresAt: new Date(now + (24 * 60 * 60 * 1000)),
      templates: [
        { id: "center-template" },
        { id: "side-template" },
      ],
    });
    await setDoc(doc(db, `events/event-1/photos/${photoId}`), {
      id: matchId,
      eventId: "event-1",
      sourceUserId: sourceUid,
      sourceInstallationId: SOURCE_INSTALLATION_ID,
      sourceMembershipId,
      assetLocalId: "asset-1",
      appearances: [{
        participantUserId: recipientUid,
        recipientMembershipId,
        confidence: 0.91,
        faceIdentityId,
        faceProfileRevision: revision,
        dismissedByUser: false,
      }],
      matchedUserIds: [recipientUid],
      matchedFaceIdentityIds: { [recipientUid]: faceIdentityId },
      matchedProfileRevisions: { [recipientUid]: revision },
      matchedMembershipIds: { [recipientUid]: recipientMembershipId },
      dismissedUserIds: [],
      dismissedMembershipIds: {},
      capturedAt,
      matchedAt: capturedAt,
      thumbnailPath,
      createdAt: capturedAt,
      updatedAt: capturedAt,
    });
  });

  return {
    capturedAt,
    faceIdentityId,
    matchId,
    photoId,
    recipientMembershipId,
    revision,
    sourceMembershipId,
    thumbnailPath,
  };
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

test("metadata-only ambiguity reconciliation revokes an old positive without requiring a thumbnail upload", async () => {
  const source = await signedInClient();
  const recipient = await signedInClient();
  const seeded = await seedPublishedMatch({ sourceUid: source.uid, recipientUid: recipient.uid });

  const publishMatch = httpsCallable(source.functions, "publishMatch");
  await publishMatch({
    id: seeded.matchId,
    eventId: "event-1",
    assetLocalId: "asset-1",
    sourceInstallationId: SOURCE_INSTALLATION_ID,
    sourceMembershipId: seeded.sourceMembershipId,
    appearances: [],
    recipientRemovals: [{
      participantUserId: recipient.uid,
      recipientMembershipId: seeded.recipientMembershipId,
      faceIdentityId: seeded.faceIdentityId,
      faceProfileRevision: seeded.revision,
    }],
    capturedAtMillis: seeded.capturedAt.getTime(),
    matchedAtMillis: Date.now(),
    thumbnailPath: seeded.thumbnailPath,
    mergeAppearances: true,
    metadataOnly: true,
  });

  await env.withSecurityRulesDisabled(async (context) => {
    const snap = await getDoc(doc(context.firestore(), `events/event-1/photos/${seeded.photoId}`));
    assert.equal(snap.exists(), true);
    const photo = snap.data();
    assert.deepEqual(photo.appearances, []);
    assert.deepEqual(photo.matchedUserIds, []);
    assert.deepEqual(photo.matchedFaceIdentityIds, {});
    assert.deepEqual(photo.matchedProfileRevisions, {});
    assert.deepEqual(photo.matchedMembershipIds, {});
    assert.equal(photo.thumbnailPath, seeded.thumbnailPath);
  });
});

test("stale recipient membership cannot revoke a match from a newer participation generation", async () => {
  const source = await signedInClient();
  const recipient = await signedInClient();
  const seeded = await seedPublishedMatch({
    sourceUid: source.uid,
    recipientUid: recipient.uid,
    recipientMembershipId: "recipient-membership-new",
  });

  const publishMatch = httpsCallable(source.functions, "publishMatch");
  await assert.rejects(() => publishMatch({
    id: seeded.matchId,
    eventId: "event-1",
    assetLocalId: "asset-1",
    sourceInstallationId: SOURCE_INSTALLATION_ID,
    sourceMembershipId: seeded.sourceMembershipId,
    appearances: [],
    recipientRemovals: [{
      participantUserId: recipient.uid,
      recipientMembershipId: "recipient-membership-old",
      faceIdentityId: seeded.faceIdentityId,
      faceProfileRevision: seeded.revision,
    }],
    capturedAtMillis: seeded.capturedAt.getTime(),
    matchedAtMillis: Date.now(),
    thumbnailPath: seeded.thumbnailPath,
    mergeAppearances: true,
    metadataOnly: true,
  }));

  await env.withSecurityRulesDisabled(async (context) => {
    const snap = await getDoc(doc(context.firestore(), `events/event-1/photos/${seeded.photoId}`));
    assert.equal(snap.exists(), true);
    assert.deepEqual(snap.data().matchedUserIds, [recipient.uid]);
    assert.equal(snap.data().matchedMembershipIds[recipient.uid], "recipient-membership-new");
  });
});
