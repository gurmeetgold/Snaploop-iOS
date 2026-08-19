const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

exports.refreshMyFaceProfileManaged = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  const uid = request.auth.uid;
  const userRef = db.doc(`users/${uid}`);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);
  const [userSnap, profileSnap, eventRefsSnap] = await Promise.all([
    userRef.get(),
    profileRef.get(),
    userRef.collection("eventRefs").get(),
  ]);

  if (!userSnap.exists) {
    throw new HttpsError("failed-precondition", "Your MyPicsRoom user profile is missing.");
  }
  if (!profileSnap.exists) {
    throw new HttpsError("failed-precondition", "Face Setup is missing.");
  }

  const user = userSnap.data() || {};
  const profile = profileSnap.data() || {};
  if (!Array.isArray(profile.embedding) || profile.embedding.length === 0) {
    throw new HttpsError("failed-precondition", "Face Setup is incomplete.");
  }

  const version = Number(profile.version || 1);
  const writer = db.batch();
  let updated = 0;

  for (const eventRefDoc of eventRefsSnap.docs) {
    const eventId = eventRefDoc.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    const memberRef = db.doc(`events/${eventId}/members/${uid}`);
    const memberSnap = await memberRef.get();
    if (!memberSnap.exists) continue;

    const member = memberSnap.data() || {};
    writer.set(participantRef, {
      userId: uid,
      displayName: user.displayName || null,
      phoneNumber: user.phoneNumber || null,
      faceEmbedding: profile.embedding,
      faceTemplates: Array.isArray(profile.templates) ? profile.templates : [],
      faceProfileVersion: version,
      joinedAt: member.joinedAt instanceof Timestamp ? member.joinedAt : Timestamp.now(),
    }, { merge: true });
    writer.update(memberRef, { faceTemplateVersion: version });
    updated += 1;
  }

  writer.set(userRef, { hasFaceProfile: true }, { merge: true });
  await writer.commit();

  return { updated, version };
});
