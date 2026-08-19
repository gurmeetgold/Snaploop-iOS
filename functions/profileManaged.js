const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();

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

  const writer = db.batch();
  let updated = 0;
  for (const eventRefDoc of eventRefsSnap.docs) {
    const eventId = eventRefDoc.id;
    const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
    const memberRef = db.doc(`events/${eventId}/members/${uid}`);
    const [participantSnap, memberSnap] = await Promise.all([participantRef.get(), memberRef.get()]);
    if (participantSnap.exists) {
      writer.update(participantRef, {
        displayName: user.displayName || null,
        phoneNumber: user.phoneNumber || null,
        faceEmbedding: profile.embedding,
        faceTemplates: Array.isArray(profile.templates) ? profile.templates : [],
        faceProfileVersion: Number(profile.version || 1),
      });
      updated += 1;
    }
    if (memberSnap.exists) {
      writer.update(memberRef, { faceTemplateVersion: Number(profile.version || 1) });
    }
  }
  if (updated > 0) await writer.commit();
  return { updated, version: Number(profile.version || 1) };
});
