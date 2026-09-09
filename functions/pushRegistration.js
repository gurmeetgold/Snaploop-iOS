"use strict";

const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { normalizePushPlatform } = require("./pushPlatform");

const db = admin.firestore();

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

function requireToken(value) {
  if (typeof value !== "string" || value.trim().length < 20 || value.length > 4096) {
    throw new HttpsError("invalid-argument", "Push token is invalid.");
  }
  return value.trim();
}

function tokenKey(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

exports.registerPushToken = onCall(async (request) => {
  const uid = requireAuth(request);
  const input = request.data || {};
  const token = requireToken(input.token);
  const platform = normalizePushPlatform(input.platform);
  const ref = db.doc(`users/${uid}/pushTokens/${tokenKey(token)}`);
  const existing = await ref.get();
  await ref.set({
    token,
    platform,
    appBundleId: typeof input.appBundleId === "string" ? input.appBundleId : null,
    createdAt: existing.exists ? existing.data().createdAt || Timestamp.now() : Timestamp.now(),
    updatedAt: Timestamp.now(),
  }, { merge: true });
  return { registered: true };
});
