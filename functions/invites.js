const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");
const { isWithinEventGraceWindow } = require("./eventDateSemantics");

const db = admin.firestore();
const PHOTO_WINDOW_DAYS = 15;

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

function inviteDecisionRef(uid, eventId) {
  return db.doc(`users/${uid}/inviteDecisions/${eventId}`);
}

async function removeInviteNotifications(uid, eventId) {
  // Avoid a composite index solely for decline cleanup. Updates is bounded on the
  // client already, so scanning a modest recent window and filtering in memory is
  // sufficient for the MVP and keeps the decline path deterministic.
  const snap = await db.collection(`users/${uid}/notifications`).limit(200).get();
  const matching = snap.docs.filter((doc) => {
    const data = doc.data() || {};
    return data.type === "event_invite" && data.eventId === eventId;
  });
  if (matching.length === 0) return;

  const batch = db.batch();
  for (const doc of matching) batch.delete(doc.ref);
  await batch.commit();
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

    // A fresh explicit invite deliberately re-opens a previously declined Event.
    // Keeping this server-side avoids stale local state making old invites reappear,
    // while still allowing an organizer to invite the member again later.
    batch.set(inviteDecisionRef(targetUserId, eventId), {
      status: "invited",
      inviteToken: event.inviteToken || null,
      updatedAt: now,
    }, { merge: true });
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

    // Decline state is account-scoped and server authoritative. This prevents a
    // reinstalled app, a second phone, or stale local UserDefaults from surfacing
    // the same pending invitation again. A new explicit invite resets this state
    // to "invited" in inviteByPhone above.
    const decisionSnap = await inviteDecisionRef(uid, eventId).get();
    if (decisionSnap.exists && decisionSnap.data()?.status === "declined") {
      const now = Timestamp.now();
      const batch = db.batch();
      batch.set(doc.ref, { status: "declined", updatedAt: now }, { merge: true });
      if (invite.phoneNumber) {
        batch.set(
          db.doc(`events/${eventId}/invites/${phoneKey(invite.phoneNumber)}`),
          { status: "declined", updatedAt: now },
          { merge: true }
        );
      }
      await batch.commit();
      await removeInviteNotifications(uid, eventId);
      continue;
    }

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
    const event = eventSnap.exists ? eventSnap.data() || {} : null;
    if (!eventSnap.exists
        || event.status !== "active"
        || !isWithinEventGraceWindow(event, Date.now(), PHOTO_WINDOW_DAYS)) {
      const now = Timestamp.now();
      const batch = db.batch();
      batch.set(doc.ref, { status: "expired", updatedAt: now }, { merge: true });
      if (invite.phoneNumber) {
        batch.set(
          db.doc(`events/${eventId}/invites/${phoneKey(invite.phoneNumber)}`),
          { status: "expired", updatedAt: now },
          { merge: true }
        );
      }
      await batch.commit();
      continue;
    }

    return {
      eventId,
      eventName: invite.eventName || event.name || "MyPicsRoom event",
      inviteToken: invite.inviteToken || event.inviteToken,
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
  const data = pending.exists ? pending.data() || {} : {};
  const now = Timestamp.now();
  const batch = db.batch();

  // Always record the account-level decision, even when the invite arrived via a
  // generic token/link and there is no pendingInvites document. This makes the
  // decline durable across sign-out/in, reinstall, and multiple phones.
  batch.set(inviteDecisionRef(uid, eventId), {
    status: "declined",
    updatedAt: now,
  }, { merge: true });

  if (pending.exists) {
    batch.set(pendingRef, { status: "declined", updatedAt: now }, { merge: true });
  }
  if (data.phoneNumber) {
    batch.set(
      db.doc(`events/${eventId}/invites/${phoneKey(data.phoneNumber)}`),
      { status: "declined", updatedAt: now },
      { merge: true }
    );
  }
  await batch.commit();

  // A decline is terminal for this invitation presentation. Remove the existing
  // invitation activity records so Home/Updates cannot keep resurfacing stale UI.
  // A later explicit organizer re-invite creates a new notification normally.
  await removeInviteNotifications(uid, eventId);

  return { eventId };
});
