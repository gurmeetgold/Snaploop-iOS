const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const MAX_PARTICIPANTS = 250;
const MAX_EVENT_DAYS = 15;
const DATE_WINDOW_DAYS = 15;
const DAY_MS = 24 * 60 * 60 * 1000;
const GRACE_PERIOD_DAYS = 3;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) throw new HttpsError("unauthenticated", "You must be signed in.");
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  return value.trim();
}

function requireMillis(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) throw new HttpsError("invalid-argument", `${name} is invalid.`);
  return n;
}

function validateEventDates(startsAtMillis, endsAtMillis) {
  if (endsAtMillis <= startsAtMillis) {
    throw new HttpsError("invalid-argument", "Event end date must be after the start date.");
  }
  if (endsAtMillis - startsAtMillis > MAX_EVENT_DAYS * DAY_MS) {
    throw new HttpsError("invalid-argument", `Events can run for up to ${MAX_EVENT_DAYS} days.`);
  }

  const now = new Date();
  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const lower = todayStart - DATE_WINDOW_DAYS * DAY_MS;
  const upper = todayStart + (DATE_WINDOW_DAYS + 1) * DAY_MS - 1;
  if (startsAtMillis < lower || startsAtMillis > upper || endsAtMillis < lower || endsAtMillis > upper) {
    throw new HttpsError(
      "invalid-argument",
      `Event dates must be within ${DATE_WINDOW_DAYS} days before today and ${DATE_WINDOW_DAYS} days after today.`
    );
  }
}

async function loadIdentity(uid, tx = null) {
  const userRef = db.doc(`users/${uid}`);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);
  const [userSnap, profileSnap] = tx
    ? await Promise.all([tx.get(userRef), tx.get(profileRef)])
    : await Promise.all([userRef.get(), profileRef.get()]);

  if (!userSnap.exists) throw new HttpsError("failed-precondition", "Your MyPicsRoom user profile is missing.");
  if (!profileSnap.exists) throw new HttpsError("failed-precondition", "Face Setup is required before joining an event.");
  const profile = profileSnap.data() || {};
  if (!Array.isArray(profile.embedding) || profile.embedding.length === 0) {
    throw new HttpsError("failed-precondition", "Face Setup is incomplete.");
  }
  return { user: userSnap.data() || {}, profile };
}

function memberData(uid, role, profile, joinedAt) {
  return {
    userId: uid,
    role,
    joinedAt,
    sharingEnabled: true,
    lastSyncAt: null,
    faceTemplateVersion: Number(profile.version || 1),
  };
}

function participantData(uid, user, profile, joinedAt) {
  return {
    userId: uid,
    displayName: user.displayName || null,
    phoneNumber: user.phoneNumber || null,
    faceEmbedding: profile.embedding,
    faceTemplates: Array.isArray(profile.templates) ? profile.templates : [],
    faceProfileVersion: Number(profile.version || 1),
    joinedAt,
  };
}

function validateJoinable(event) {
  if (event.status !== "active") throw new HttpsError("failed-precondition", "This event has ended.");
  if (!(event.endsAt instanceof Timestamp)) throw new HttpsError("failed-precondition", "This event has invalid dates.");
  if (Date.now() > event.endsAt.toMillis() + GRACE_PERIOD_DAYS * DAY_MS) {
    throw new HttpsError("failed-precondition", "This event has expired.");
  }
}

async function memberRole(eventId, uid) {
  const snap = await db.doc(`events/${eventId}/members/${uid}`).get();
  return snap.exists ? snap.data().role : null;
}

async function eventName(eventId) {
  const snap = await db.doc(`events/${eventId}`).get();
  return snap.exists ? (snap.data().name || "MyPicsRoom event") : "MyPicsRoom event";
}

async function notifyCurrentMembers(eventId, actorUid, body, type) {
  const members = await db.collection(`events/${eventId}/members`).get();
  const name = await eventName(eventId);
  const batch = db.batch();
  const createdAt = Timestamp.now();
  let count = 0;
  for (const member of members.docs) {
    if (member.id === actorUid) continue;
    const ref = db.collection(`users/${member.id}/notifications`).doc();
    batch.set(ref, {
      type,
      eventId,
      eventName: name,
      title: name,
      body,
      createdAt,
      read: false,
    });
    count += 1;
  }
  if (count > 0) await batch.commit();
}

exports.createEventMVP = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const id = requireString(data.id, "id");
  const joinCode = requireString(data.joinCode, "joinCode").toUpperCase();
  const inviteToken = requireString(data.inviteToken, "inviteToken");
  const creatorUserId = requireString(data.creatorUserId, "creatorUserId");
  const name = requireString(data.name, "name");
  const category = requireString(data.category, "category");
  if (creatorUserId !== uid) throw new HttpsError("permission-denied", "Creator identity does not match the signed-in user.");
  if (data.status !== "active") throw new HttpsError("invalid-argument", "New events must start active.");

  const startsAtMillis = requireMillis(data.startsAtMillis, "startsAt");
  const endsAtMillis = requireMillis(data.endsAtMillis, "endsAt");
  validateEventDates(startsAtMillis, endsAtMillis);
  const createdAtMillis = requireMillis(data.createdAtMillis, "createdAt");
  const updatedAtMillis = requireMillis(data.updatedAtMillis, "updatedAt");
  const { user, profile } = await loadIdentity(uid);

  const eventRef = db.doc(`events/${id}`);
  const codeRef = db.doc(`joinCodes/${joinCode}`);
  const tokenRef = db.doc(`inviteTokens/${inviteToken}`);
  const memberRef = db.doc(`events/${id}/members/${uid}`);
  const participantRef = db.doc(`events/${id}/participants/${uid}`);
  const userEventRef = db.doc(`users/${uid}/eventRefs/${id}`);

  await db.runTransaction(async (tx) => {
    const [eventSnap, codeSnap, tokenSnap] = await Promise.all([tx.get(eventRef), tx.get(codeRef), tx.get(tokenRef)]);
    if (eventSnap.exists || codeSnap.exists || tokenSnap.exists) {
      throw new HttpsError("already-exists", "Event identity collision. Please create the event again.");
    }
    const joinedAt = Timestamp.now();
    tx.create(eventRef, {
      id, joinCode, inviteToken, creatorUserId: uid, name, category,
      coverImagePath: typeof data.coverImagePath === "string" ? data.coverImagePath : null,
      locationName: typeof data.locationName === "string" ? data.locationName : null,
      startsAt: Timestamp.fromMillis(startsAtMillis),
      endsAt: Timestamp.fromMillis(endsAtMillis),
      status: "active",
      createdAt: Timestamp.fromMillis(createdAtMillis),
      updatedAt: Timestamp.fromMillis(updatedAtMillis),
      memberCount: 1,
    });
    tx.create(codeRef, { eventId: id, createdAt: joinedAt });
    tx.create(tokenRef, { eventId: id, createdAt: joinedAt });
    tx.create(memberRef, memberData(uid, "organizer", profile, joinedAt));
    tx.create(participantRef, participantData(uid, user, profile, joinedAt));
    tx.set(userEventRef, { eventId: id, joinedAt, role: "organizer" });
  });
  return { eventId: id };
});

exports.joinEventManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  const eventRef = db.doc(`events/${eventId}`);
  const memberRef = db.doc(`events/${eventId}/members/${uid}`);
  const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
  const userEventRef = db.doc(`users/${uid}/eventRefs/${eventId}`);
  let joined = false;
  let joinedName = "A member";

  await db.runTransaction(async (tx) => {
    const eventSnap = await tx.get(eventRef);
    if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
    const event = eventSnap.data();
    validateJoinable(event);
    const memberSnap = await tx.get(memberRef);
    if (memberSnap.exists) return;
    const { user, profile } = await loadIdentity(uid, tx);
    const count = Number(event.memberCount || 0);
    if (count >= MAX_PARTICIPANTS) throw new HttpsError("resource-exhausted", "This event is full.");
    const joinedAt = Timestamp.now();
    tx.create(memberRef, memberData(uid, "participant", profile, joinedAt));
    tx.create(participantRef, participantData(uid, user, profile, joinedAt));
    tx.set(userEventRef, { eventId, joinedAt, role: "participant" });
    tx.update(eventRef, { memberCount: count + 1 });
    joined = true;
    joinedName = user.displayName || "A member";
  });

  if (joined) await notifyCurrentMembers(eventId, uid, `${joinedName} joined the event.`, "member_joined");
  return { eventId, joined };
});

exports.updateEventManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const eventRef = db.doc(`events/${eventId}`);
  const [eventSnap, role] = await Promise.all([eventRef.get(), memberRole(eventId, uid)]);
  if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
  if (role !== "organizer") throw new HttpsError("permission-denied", "Only the organizer can edit this event.");

  const current = eventSnap.data();
  const update = { updatedAt: Timestamp.now() };
  const changes = [];

  if (typeof data.name === "string") {
    const name = requireString(data.name, "name");
    if (name !== current.name) { update.name = name; changes.push("name"); }
  }
  if (typeof data.category === "string" && data.category !== current.category) {
    update.category = data.category; changes.push("details");
  }
  if (Object.prototype.hasOwnProperty.call(data, "locationName")) {
    const locationName = typeof data.locationName === "string" && data.locationName.trim() ? data.locationName.trim() : null;
    if (locationName !== (current.locationName || null)) { update.locationName = locationName; changes.push("details"); }
  }
  if (Object.prototype.hasOwnProperty.call(data, "coverImagePath")) {
    const cover = typeof data.coverImagePath === "string" ? data.coverImagePath : null;
    if (cover !== (current.coverImagePath || null)) { update.coverImagePath = cover; changes.push("details"); }
  }

  if (data.startsAtMillis !== undefined || data.endsAtMillis !== undefined) {
    const starts = data.startsAtMillis !== undefined ? requireMillis(data.startsAtMillis, "startsAt") : current.startsAt.toMillis();
    const ends = data.endsAtMillis !== undefined ? requireMillis(data.endsAtMillis, "endsAt") : current.endsAt.toMillis();
    validateEventDates(starts, ends);
    if (starts !== current.startsAt.toMillis() || ends !== current.endsAt.toMillis()) {
      update.startsAt = Timestamp.fromMillis(starts);
      update.endsAt = Timestamp.fromMillis(ends);
      changes.push("dates");
    }
  }

  if (changes.length === 0) return { eventId, changed: false };
  await eventRef.update(update);
  const unique = [...new Set(changes)];
  const body = unique.includes("dates")
    ? "The organizer updated the event dates."
    : unique.includes("name")
      ? "The organizer updated the event name."
      : "The organizer updated the event details.";
  await notifyCurrentMembers(eventId, uid, body, "event_updated");
  return { eventId, changed: true };
});

exports.manageEventMember = onCall(async (request) => {
  const actorUid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const targetUid = requireString(data.userId, "userId");
  const action = requireString(data.action, "action");
  const eventRef = db.doc(`events/${eventId}`);
  const actorRef = db.doc(`events/${eventId}/members/${actorUid}`);
  const targetRef = db.doc(`events/${eventId}/members/${targetUid}`);
  const participantRef = db.doc(`events/${eventId}/participants/${targetUid}`);
  const userEventRef = db.doc(`users/${targetUid}/eventRefs/${eventId}`);

  let notificationBody = null;
  let notificationType = null;
  await db.runTransaction(async (tx) => {
    const [eventSnap, actorSnap, targetSnap] = await Promise.all([tx.get(eventRef), tx.get(actorRef), tx.get(targetRef)]);
    if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
    if (!targetSnap.exists) throw new HttpsError("not-found", "This member is no longer in the event.");
    const actorRole = actorSnap.exists ? actorSnap.data().role : null;
    const targetRole = targetSnap.data().role;

    if (action === "setRole") {
      if (actorRole !== "organizer") throw new HttpsError("permission-denied", "Only the organizer can change Admin roles.");
      if (targetRole === "organizer") throw new HttpsError("failed-precondition", "The organizer role cannot be changed.");
      const newRole = requireString(data.role, "role");
      if (newRole !== "admin" && newRole !== "participant") throw new HttpsError("invalid-argument", "Role must be Admin or Member.");
      if (newRole === targetRole) return;
      tx.update(targetRef, { role: newRole });
      tx.set(userEventRef, { role: newRole }, { merge: true });
      notificationBody = newRole === "admin" ? "A member was promoted to Admin." : "An Admin was changed to Member.";
      notificationType = "member_role_changed";
      return;
    }

    if (action === "remove") {
      const removingSelf = actorUid === targetUid;
      const organizerCanRemove = actorRole === "organizer" && targetRole !== "organizer";
      const adminCanRemove = actorRole === "admin" && targetRole === "participant";
      if (!removingSelf && !organizerCanRemove && !adminCanRemove) {
        throw new HttpsError("permission-denied", "You cannot remove this member.");
      }
      if (targetRole === "organizer") throw new HttpsError("failed-precondition", "The organizer cannot be removed.");
      const count = Math.max(0, Number(eventSnap.data().memberCount || 1) - 1);
      tx.delete(targetRef);
      tx.delete(participantRef);
      tx.delete(userEventRef);
      tx.update(eventRef, { memberCount: count });
      notificationBody = "A member was removed from the event.";
      notificationType = "member_removed";
      return;
    }

    throw new HttpsError("invalid-argument", "Unknown member action.");
  });

  if (notificationBody) await notifyCurrentMembers(eventId, actorUid, notificationBody, notificationType);
  return { eventId, userId: targetUid };
});

exports.inviteByPhoneManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const role = await memberRole(eventId, uid);
  if (role !== "organizer" && role !== "admin") throw new HttpsError("permission-denied", "Only the organizer or an Admin can invite people.");

  const rawPhone = requireString(data.phoneNumber, "phoneNumber").replace(/[\s().-]/g, "");
  if (!/^\+[1-9][0-9]{7,14}$/.test(rawPhone)) throw new HttpsError("invalid-argument", "Use a valid international phone number.");
  const eventSnap = await db.doc(`events/${eventId}`).get();
  if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
  const event = eventSnap.data();
  if (event.status !== "active") throw new HttpsError("failed-precondition", "This event has ended.");

  const users = await db.collection("users").where("phoneNumber", "==", rawPhone).limit(1).get();
  const existing = users.empty ? null : users.docs[0];
  const targetUserId = existing ? existing.id : null;
  const key = rawPhone.replace(/\D/g, "");
  const now = Timestamp.now();
  const invite = {
    eventId,
    eventName: event.name || "MyPicsRoom event",
    inviteToken: event.inviteToken,
    phoneNumber: rawPhone,
    targetUserId,
    invitedByUserId: uid,
    status: "invited",
    createdAt: now,
    updatedAt: now,
    endsAt: event.endsAt || null,
  };
  const batch = db.batch();
  batch.set(db.doc(`events/${eventId}/invites/${key}`), invite, { merge: true });
  if (targetUserId) batch.set(db.doc(`users/${targetUserId}/pendingInvites/${eventId}`), invite, { merge: true });
  await batch.commit();
  return { delivery: targetUserId ? "in_app" : "sms", eventId, phoneNumber: rawPhone, targetUserId, inviteToken: event.inviteToken };
});

exports.listEventInvitesManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const eventId = requireString((request.data || {}).eventId, "eventId");
  const role = await memberRole(eventId, uid);
  if (role !== "organizer" && role !== "admin") throw new HttpsError("permission-denied", "Only the organizer or an Admin can view invitations.");
  const snap = await db.collection(`events/${eventId}/invites`).orderBy("createdAt", "desc").limit(100).get();
  const rows = snap.docs.map((doc) => {
    const data = doc.data();
    return {
      phoneNumber: data.phoneNumber || "",
      status: data.status || "invited",
      delivery: data.targetUserId ? "in_app" : "sms",
      createdAtMillis: data.createdAt && data.createdAt.toMillis ? data.createdAt.toMillis() : null,
    };
  });
  return { invites: rows };
});
