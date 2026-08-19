const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "You must be signed in.");
  }
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

function normalizeE164(raw) {
  const value = requireString(raw, "phoneNumber").replace(/[\s().-]/g, "");
  if (!/^\+[1-9][0-9]{7,14}$/.test(value)) {
    throw new HttpsError("invalid-argument", "Use a valid international phone number.");
  }
  return value;
}

function phoneKey(phone) {
  return phone.replace(/\D/g, "");
}

async function requireOrganizer(eventId, uid) {
  const eventRef = db.doc(`events/${eventId}`);
  const eventSnap = await eventRef.get();
  if (!eventSnap.exists) {
    throw new HttpsError("not-found", "This event does not exist.");
  }
  const event = eventSnap.data();
  if (event.creatorUserId !== uid) {
    throw new HttpsError("permission-denied", "Only the organizer can invite by phone right now.");
  }
  if (event.status !== "active") {
    throw new HttpsError("failed-precondition", "This event has ended.");
  }
  return { eventRef, event };
}

exports.inviteByPhone = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const phoneNumber = normalizeE164(data.phoneNumber);
  const { event } = await requireOrganizer(eventId, uid);

  const users = await db.collection("users")
    .where("phoneNumber", "==", phoneNumber)
    .limit(1)
    .get();
  const existing = users.empty ? null : users.docs[0];
  const targetUserId = existing ? existing.id : null;
  const key = phoneKey(phoneNumber);
  const inviteRef = db.doc(`events/${eventId}/invites/${key}`);
  const now = Timestamp.now();

  const invite = {
    eventId,
    eventName: event.name || "MyPicsRoom event",
    inviteToken: event.inviteToken,
    phoneNumber,
    targetUserId,
    invitedByUserId: uid,
    status: "invited",
    createdAt: now,
    updatedAt: now,
    endsAt: event.endsAt || null,
  };

  const batch = db.batch();
  batch.set(inviteRef, invite, { merge: true });

  if (targetUserId) {
    const pendingRef = db.doc(`users/${targetUserId}/pendingInvites/${eventId}`);
    batch.set(pendingRef, invite, { merge: true });
  }
  await batch.commit();

  return {
    delivery: targetUserId ? "in_app" : "sms",
    eventId,
    phoneNumber,
    targetUserId: targetUserId || null,
    inviteToken: event.inviteToken,
  };
});

exports.nextPendingInvite = onCall(async (request) => {
  const uid = requireAuth(request);

  // Do not combine equality filtering with createdAt ordering here. Keeping this
  // as a single-field query avoids a needless composite Firestore index for the
  // MVP. The small result set is sorted in memory instead.
  const snap = await db.collection(`users/${uid}/pendingInvites`)
    .where("status", "==", "invited")
    .limit(20)
    .get();

  const docs = [...snap.docs].sort((a, b) => {
    const at = a.data().createdAt;
    const bt = b.data().createdAt;
    const am = at && typeof at.toMillis === "function" ? at.toMillis() : 0;
    const bm = bt && typeof bt.toMillis === "function" ? bt.toMillis() : 0;
    return am - bm;
  });

  for (const doc of docs) {
    const invite = doc.data();
    const eventId = invite.eventId || doc.id;
    const memberSnap = await db.doc(`events/${eventId}/members/${uid}`).get();
    if (memberSnap.exists) {
      await doc.ref.set({ status: "joined", updatedAt: Timestamp.now() }, { merge: true });
      if (invite.phoneNumber) {
        await db.doc(`events/${eventId}/invites/${phoneKey(invite.phoneNumber)}`)
          .set({ status: "joined", updatedAt: Timestamp.now() }, { merge: true });
      }
      continue;
    }

    const eventSnap = await db.doc(`events/${eventId}`).get();
    if (!eventSnap.exists || eventSnap.data().status !== "active") {
      await doc.ref.set({ status: "expired", updatedAt: Timestamp.now() }, { merge: true });
      continue;
    }

    return {
      eventId,
      eventName: invite.eventName || eventSnap.data().name || "MyPicsRoom event",
      inviteToken: invite.inviteToken || eventSnap.data().inviteToken,
      status: "invited",
    };
  }

  return { invite: null };
});

exports.listEventInvites = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  await requireOrganizer(eventId, uid);

  const snap = await db.collection(`events/${eventId}/invites`)
    .orderBy("createdAt", "desc")
    .limit(100)
    .get();

  const rows = [];
  for (const doc of snap.docs) {
    const data = doc.data();
    let status = data.status || "invited";
    if (data.targetUserId && status === "invited") {
      const member = await db.doc(`events/${eventId}/members/${data.targetUserId}`).get();
      if (member.exists) {
        status = "joined";
        await doc.ref.set({ status: "joined", updatedAt: Timestamp.now() }, { merge: true });
      }
    }
    rows.push({
      phoneNumber: data.phoneNumber || "",
      status,
      delivery: data.targetUserId ? "in_app" : "sms",
      createdAtMillis: data.createdAt && data.createdAt.toMillis ? data.createdAt.toMillis() : null,
    });
  }
  return { invites: rows };
});

exports.declineEventInvite = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  const pendingRef = db.doc(`users/${uid}/pendingInvites/${eventId}`);
  const pending = await pendingRef.get();
  if (!pending.exists) return { eventId };

  const data = pending.data();
  const batch = db.batch();
  batch.set(pendingRef, { status: "declined", updatedAt: Timestamp.now() }, { merge: true });
  if (data.phoneNumber) {
    batch.set(
      db.doc(`events/${eventId}/invites/${phoneKey(data.phoneNumber)}`),
      { status: "declined", updatedAt: Timestamp.now() },
      { merge: true }
    );
  }
  await batch.commit();
  return { eventId };
});
