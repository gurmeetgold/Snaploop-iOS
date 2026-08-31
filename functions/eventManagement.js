const { onCall, HttpsError } = require("firebase-functions/https");
const { randomUUID } = require("crypto");
const admin = require("firebase-admin");
const {
  DAY_MS,
  PHOTO_WINDOW_VERSION,
  validateEventDatePayload,
} = require("./eventDateSemantics");

const db = admin.firestore();
const Timestamp = admin.firestore.Timestamp;
const FieldValue = admin.firestore.FieldValue;
const MAX_PARTICIPANTS = 250;
// Keep the Event open for late joins and photo recovery after it ends. This is
// deliberately the same 15-day product window used by the launch MVP.
const GRACE_PERIOD_DAYS = 15;
const MAX_EVENT_NAME_LENGTH = 80;
const MAX_LOCATION_LENGTH = 120;
const EVENT_CATEGORIES = new Set([
  "trip", "wedding", "party", "birthday", "conference", "family", "sports", "other",
]);

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
  return Math.round(n);
}

function validateEventName(value) {
  const name = requireString(value, "name");
  if (name.length > MAX_EVENT_NAME_LENGTH) {
    throw new HttpsError("invalid-argument", `Event name must be ${MAX_EVENT_NAME_LENGTH} characters or fewer.`);
  }
  return name;
}

function validateCategory(value) {
  const category = requireString(value, "category");
  if (!EVENT_CATEGORIES.has(category)) {
    throw new HttpsError("invalid-argument", "Event category is invalid.");
  }
  return category;
}

function normalizeLocation(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") throw new HttpsError("invalid-argument", "Location is invalid.");
  const location = value.trim();
  if (!location) return null;
  if (location.length > MAX_LOCATION_LENGTH) {
    throw new HttpsError("invalid-argument", `Location must be ${MAX_LOCATION_LENGTH} characters or fewer.`);
  }
  return location;
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
    membershipId: randomUUID(),
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
    throw new HttpsError("failed-precondition", "This event's photo window has expired.");
  }
}

async function memberRole(eventId, uid) {
  const snap = await db.doc(`events/${eventId}/members/${uid}`).get();
  return snap.exists ? snap.data().role : null;
}

async function eventName(eventId) {
  const snap = await db.doc(`events/${eventId}`).get();
  return snap.exists ? (snap.data().name || "SnapLoop Event") : "SnapLoop Event";
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

async function notifyMember(eventId, userId, title, body, type) {
  const name = await eventName(eventId);
  const ref = db.collection(`users/${userId}/notifications`).doc();
  await ref.set({
    type,
    eventId,
    eventName: name,
    title,
    body,
    createdAt: Timestamp.now(),
    read: false,
  });
}

exports.createEventMVP = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const id = requireString(data.id, "id");
  const joinCode = requireString(data.joinCode, "joinCode").toUpperCase();
  const inviteToken = requireString(data.inviteToken, "inviteToken");
  const creatorUserId = requireString(data.creatorUserId, "creatorUserId");
  const name = validateEventName(data.name);
  const category = validateCategory(data.category);
  if (creatorUserId !== uid) throw new HttpsError("permission-denied", "Creator identity does not match the signed-in user.");
  if (data.status !== "active") throw new HttpsError("invalid-argument", "New events must start active.");

  const window = validateEventDatePayload(data);
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
    const persistedWindow = window.photoWindowVersion === PHOTO_WINDOW_VERSION
      ? {
          photoWindowVersion: PHOTO_WINDOW_VERSION,
          photoWindowTimeZoneId: window.photoWindowTimeZoneId,
          photoWindowStartDayNumber: window.startDay,
          photoWindowEndDayNumber: window.endDay,
        }
      : {};

    tx.create(eventRef, {
      id, joinCode, inviteToken, creatorUserId: uid, name, category,
      coverImagePath: typeof data.coverImagePath === "string" ? data.coverImagePath : null,
      locationName: normalizeLocation(data.locationName),
      startsAt: Timestamp.fromMillis(window.startsAtMillis),
      endsAt: Timestamp.fromMillis(window.endsAtMillis),
      ...persistedWindow,
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

  if (joined) await notifyCurrentMembers(eventId, uid, `${joinedName} joined the Event.`, "member_joined");
  return { eventId, joined };
});

// Retained for direct module compatibility. bootstrap.js routes the production
// updateEventManaged alias to tripManager.updateTripManaged, which enforces the
// same canonical date contract and notification behavior.
exports.updateEventManaged = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const eventRef = db.doc(`events/${eventId}`);
  const actorRef = db.doc(`events/${eventId}/members/${uid}`);
  const expectedUpdatedAtMillis = data.expectedUpdatedAtMillis === undefined
    ? null
    : requireMillis(data.expectedUpdatedAtMillis, "expectedUpdatedAt");

  let changes = [];
  let changed = false;

  await db.runTransaction(async (tx) => {
    const [eventSnap, actorSnap] = await Promise.all([tx.get(eventRef), tx.get(actorRef)]);
    if (!eventSnap.exists) throw new HttpsError("not-found", "This event does not exist.");
    const actorRole = actorSnap.exists ? actorSnap.data().role : null;
    if (actorRole !== "organizer" && actorRole !== "admin") {
      throw new HttpsError("permission-denied", "Only the organizer or an Admin can edit this Event.");
    }

    const current = eventSnap.data();
    if (
      expectedUpdatedAtMillis !== null &&
      current.updatedAt instanceof Timestamp &&
      Math.abs(current.updatedAt.toMillis() - expectedUpdatedAtMillis) > 1
    ) {
      throw new HttpsError(
        "aborted",
        "This event changed on another device. Refresh before saving."
      );
    }

    const update = { updatedAt: Timestamp.now() };
    const nextChanges = [];

    if (typeof data.name === "string") {
      const nextName = validateEventName(data.name);
      if (nextName !== current.name) { update.name = nextName; nextChanges.push("name"); }
    }
    if (typeof data.category === "string") {
      const nextCategory = validateCategory(data.category);
      if (nextCategory !== current.category) { update.category = nextCategory; nextChanges.push("details"); }
    }
    if (Object.prototype.hasOwnProperty.call(data, "locationName")) {
      const locationName = normalizeLocation(data.locationName);
      if (locationName !== (current.locationName || null)) { update.locationName = locationName; nextChanges.push("details"); }
    }
    if (Object.prototype.hasOwnProperty.call(data, "coverImagePath")) {
      const cover = typeof data.coverImagePath === "string" ? data.coverImagePath : null;
      if (cover !== (current.coverImagePath || null)) { update.coverImagePath = cover; nextChanges.push("details"); }
    }

    if (data.startsAtMillis !== undefined || data.endsAtMillis !== undefined) {
      const starts = data.startsAtMillis !== undefined ? requireMillis(data.startsAtMillis, "startsAt") : current.startsAt.toMillis();
      const ends = data.endsAtMillis !== undefined ? requireMillis(data.endsAtMillis, "endsAt") : current.endsAt.toMillis();
      if (starts !== current.startsAt.toMillis() || ends !== current.endsAt.toMillis()) {
        const validated = validateEventDatePayload({ ...data, startsAtMillis: starts, endsAtMillis: ends });
        update.startsAt = Timestamp.fromMillis(validated.startsAtMillis);
        update.endsAt = Timestamp.fromMillis(validated.endsAtMillis);
        if (validated.photoWindowVersion === PHOTO_WINDOW_VERSION) {
          update.photoWindowVersion = PHOTO_WINDOW_VERSION;
          update.photoWindowTimeZoneId = validated.photoWindowTimeZoneId;
          update.photoWindowStartDayNumber = validated.startDay;
          update.photoWindowEndDayNumber = validated.endDay;
        } else if (Number(current.photoWindowVersion || 0) === PHOTO_WINDOW_VERSION) {
          update.photoWindowVersion = FieldValue.delete();
          update.photoWindowTimeZoneId = FieldValue.delete();
          update.photoWindowStartDayNumber = FieldValue.delete();
          update.photoWindowEndDayNumber = FieldValue.delete();
        }
        nextChanges.push("dates");
      }
    }

    if (nextChanges.length === 0) return;
    tx.update(eventRef, update);
    changes = nextChanges;
    changed = true;
  });

  if (!changed) return { eventId, changed: false };
  const unique = [...new Set(changes)];
  const body = unique.includes("dates")
    ? "Event dates were updated. SnapLoop will use the new dates the next time you scan Event photos."
    : unique.includes("name")
      ? "The Event name was updated."
      : "The Event details were updated.";
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

  let broadcastBody = null;
  let broadcastType = null;
  let roleNotification = null;
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
      roleNotification = newRole;
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
      broadcastBody = "A member was removed from the Event.";
      broadcastType = "member_removed";
      return;
    }

    throw new HttpsError("invalid-argument", "Unknown member action.");
  });

  if (roleNotification) {
    const name = await eventName(eventId);
    if (roleNotification === "admin") {
      await notifyMember(
        eventId,
        targetUid,
        "You're now an Admin",
        `You're now an Admin of ${name}.`,
        "member_role_changed"
      );
    } else {
      await notifyMember(
        eventId,
        targetUid,
        "Your Event role changed",
        `Your role in ${name} is now Member.`,
        "member_role_changed"
      );
    }
  } else if (broadcastBody) {
    await notifyCurrentMembers(eventId, actorUid, broadcastBody, broadcastType);
  }
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
  validateJoinable(event);

  const users = await db.collection("users").where("phoneNumber", "==", rawPhone).limit(1).get();
  const existing = users.empty ? null : users.docs[0];
  const targetUserId = existing ? existing.id : null;
  const key = rawPhone.replace(/\D/g, "");
  const now = Timestamp.now();
  const invite = {
    eventId,
    eventName: event.name || "SnapLoop Event",
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
