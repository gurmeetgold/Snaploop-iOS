const { onCall, HttpsError } = require("firebase-functions/https");
const admin = require("firebase-admin");
const { Timestamp } = require("firebase-admin/firestore");

admin.initializeApp();

const db = admin.firestore();

// Keep these aligned with the shipped RemoteConfigValues defaults for MVP.
const MAX_PARTICIPANTS = 250;
const GRACE_PERIOD_DAYS = 3;

function requireAuth(request) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError(
      "unauthenticated",
      "You must be signed in."
    );
  }
  return request.auth.uid;
}

function requireString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError(
      "invalid-argument",
      `${name} is required.`
    );
  }
  return value.trim();
}

function requireMillis(value, name) {
  const n = Number(value);
  if (!Number.isFinite(n)) {
    throw new HttpsError(
      "invalid-argument",
      `${name} is invalid.`
    );
  }
  return n;
}

function eventResponse(eventId, data) {
  const toMillis = (value) => {
    if (value && typeof value.toMillis === "function") {
      return value.toMillis();
    }
    return null;
  };

  return {
    id: eventId,
    joinCode: data.joinCode,
    inviteToken: data.inviteToken,
    creatorUserId: data.creatorUserId,
    name: data.name,
    category: data.category,
    coverImagePath: data.coverImagePath ?? null,
    locationName: data.locationName ?? null,
    startsAtMillis: toMillis(data.startsAt),
    endsAtMillis: toMillis(data.endsAt),
    status: data.status,
    createdAtMillis: toMillis(data.createdAt),
    updatedAtMillis: toMillis(data.updatedAt),
  };
}

async function loadIdentity(uid, transaction = null) {
  const userRef = db.doc(`users/${uid}`);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);

  const [userSnap, profileSnap] = transaction
    ? await Promise.all([
        transaction.get(userRef),
        transaction.get(profileRef),
      ])
    : await Promise.all([
        userRef.get(),
        profileRef.get(),
      ]);

  if (!userSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Your SnapLoop user profile is missing."
    );
  }

  if (!profileSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Face setup is required before joining an event."
    );
  }

  const user = userSnap.data();
  const profile = profileSnap.data();

  if (!Array.isArray(profile.embedding) || profile.embedding.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "Face setup is incomplete."
    );
  }

  return {
    user,
    profile,
    userRef,
    profileRef,
  };
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
  if (event.status !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "This event has ended."
    );
  }

  if (!(event.endsAt instanceof Timestamp)) {
    throw new HttpsError(
      "failed-precondition",
      "This event has invalid dates."
    );
  }

  const graceMillis = GRACE_PERIOD_DAYS * 24 * 60 * 60 * 1000;
  if (Date.now() > event.endsAt.toMillis() + graceMillis) {
    throw new HttpsError(
      "failed-precondition",
      "This event has expired."
    );
  }
}

// Creates an event plus organizer membership/participant and private lookup
// indexes atomically.
exports.createEvent = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};

  const id = requireString(data.id, "id");
  const joinCode = requireString(data.joinCode, "joinCode").toUpperCase();
  const inviteToken = requireString(data.inviteToken, "inviteToken");
  const creatorUserId = requireString(data.creatorUserId, "creatorUserId");
  const name = requireString(data.name, "name");
  const category = requireString(data.category, "category");
  const status = requireString(data.status, "status");

  if (creatorUserId !== uid) {
    throw new HttpsError(
      "permission-denied",
      "Creator identity does not match the signed-in user."
    );
  }

  if (status !== "active") {
    throw new HttpsError(
      "invalid-argument",
      "New events must start active."
    );
  }

  const startsAtMillis = requireMillis(data.startsAtMillis, "startsAt");
  const endsAtMillis = requireMillis(data.endsAtMillis, "endsAt");
  const createdAtMillis = requireMillis(data.createdAtMillis, "createdAt");
  const updatedAtMillis = requireMillis(data.updatedAtMillis, "updatedAt");

  if (endsAtMillis < startsAtMillis) {
    throw new HttpsError(
      "invalid-argument",
      "Event dates are invalid."
    );
  }

  const eventRef = db.doc(`events/${id}`);
  const codeRef = db.doc(`joinCodes/${joinCode}`);
  const tokenRef = db.doc(`inviteTokens/${inviteToken}`);
  const memberRef = db.doc(`events/${id}/members/${uid}`);
  const participantRef = db.doc(`events/${id}/participants/${uid}`);
  const eventRefForUser = db.doc(`users/${uid}/eventRefs/${id}`);

  const { user, profile } = await loadIdentity(uid);

  try {
    await db.runTransaction(async (tx) => {
      const [eventSnap, codeSnap, tokenSnap] = await Promise.all([
        tx.get(eventRef),
        tx.get(codeRef),
        tx.get(tokenRef),
      ]);

      if (eventSnap.exists || codeSnap.exists || tokenSnap.exists) {
        throw new HttpsError(
          "already-exists",
          "Event identity collision. Please create the event again."
        );
      }

      const joinedAt = Timestamp.now();

      tx.create(eventRef, {
        id,
        joinCode,
        inviteToken,
        creatorUserId: uid,
        name,
        category,
        coverImagePath:
          typeof data.coverImagePath === "string" ? data.coverImagePath : null,
        locationName:
          typeof data.locationName === "string" ? data.locationName : null,
        startsAt: Timestamp.fromMillis(startsAtMillis),
        endsAt: Timestamp.fromMillis(endsAtMillis),
        status: "active",
        createdAt: Timestamp.fromMillis(createdAtMillis),
        updatedAt: Timestamp.fromMillis(updatedAtMillis),
        memberCount: 1,
      });

      tx.create(codeRef, {
        eventId: id,
        createdAt: joinedAt,
      });

      tx.create(tokenRef, {
        eventId: id,
        createdAt: joinedAt,
      });

      tx.create(
        memberRef,
        memberData(uid, "organizer", profile, joinedAt)
      );

      tx.create(
        participantRef,
        participantData(uid, user, profile, joinedAt)
      );

      tx.set(eventRefForUser, {
        eventId: id,
        joinedAt,
        role: "organizer",
      });
    });

    return { eventId: id };
  } catch (error) {
    if (error instanceof HttpsError) {
      throw error;
    }
    console.error("createEvent failed", error);
    throw new HttpsError(
      "internal",
      "Could not create the event."
    );
  }
});

// Resolves a code/token without granting membership.
exports.resolveInvite = onCall(async (request) => {
  requireAuth(request);
  const data = request.data || {};

  const hasCode = typeof data.joinCode === "string";
  const hasToken = typeof data.inviteToken === "string";

  if (hasCode === hasToken) {
    throw new HttpsError(
      "invalid-argument",
      "Provide exactly one join code or invite token."
    );
  }

  let lookupRef;

  if (hasCode) {
    const code = requireString(data.joinCode, "join code").toUpperCase();
    lookupRef = db.doc(`joinCodes/${code}`);
  } else {
    const token = requireString(data.inviteToken, "invite token");
    lookupRef = db.doc(`inviteTokens/${token}`);
  }

  const lookupSnap = await lookupRef.get();

  if (!lookupSnap.exists) {
    throw new HttpsError(
      "not-found",
      hasCode ? "That join code does not exist." : "That invite does not exist."
    );
  }

  const eventId = lookupSnap.data().eventId;
  const eventSnap = await db.doc(`events/${eventId}`).get();

  if (!eventSnap.exists) {
    throw new HttpsError(
      "not-found",
      "That event does not exist."
    );
  }

  return {
    event: eventResponse(eventSnap.id, eventSnap.data()),
  };
});

// Creates membership + participant roster entry + user eventRef atomically.
exports.joinEvent = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");

  const eventRef = db.doc(`events/${eventId}`);
  const memberRef = db.doc(`events/${eventId}/members/${uid}`);
  const participantRef = db.doc(`events/${eventId}/participants/${uid}`);
  const eventRefForUser = db.doc(`users/${uid}/eventRefs/${eventId}`);

  try {
    await db.runTransaction(async (tx) => {
      const eventSnap = await tx.get(eventRef);

      if (!eventSnap.exists) {
        throw new HttpsError(
          "not-found",
          "This event does not exist."
        );
      }

      const event = eventSnap.data();
      validateJoinable(event);

      const memberSnap = await tx.get(memberRef);

      if (memberSnap.exists) {
        return;
      }

      const { user, profile } = await loadIdentity(uid, tx);

      const count = Number(event.memberCount || 0);

      if (count >= MAX_PARTICIPANTS) {
        throw new HttpsError(
          "resource-exhausted",
          "This event is full."
        );
      }

      const joinedAt = Timestamp.now();

      tx.create(
        memberRef,
        memberData(uid, "participant", profile, joinedAt)
      );

      tx.create(
        participantRef,
        participantData(uid, user, profile, joinedAt)
      );

      tx.set(eventRefForUser, {
        eventId,
        joinedAt,
        role: "participant",
      });

      tx.update(eventRef, {
        memberCount: count + 1,
      });
    });

    return { eventId };
  } catch (error) {
    if (error instanceof HttpsError) {
      throw error;
    }
    console.error("joinEvent failed", error);
    throw new HttpsError(
      "internal",
      "Could not join the event."
    );
  }
});


// Updates the signed-in user's display name and refreshes their display name
// snapshot in every event they currently belong to.
exports.updateDisplayName = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const displayName = requireString(data.displayName, "displayName");

  if (displayName.length < 2 || displayName.length > 40) {
    throw new HttpsError(
      "invalid-argument",
      "Display name must be between 2 and 40 characters."
    );
  }

  const userRef = db.doc(`users/${uid}`);

  await userRef.update({
    displayName,
  });

  const eventRefsSnap = await userRef.collection("eventRefs").get();

  await Promise.all(
    eventRefsSnap.docs.map(async (eventRefDoc) => {
      const eventId = eventRefDoc.id;
      const participantRef = db.doc(
        `events/${eventId}/participants/${uid}`
      );

      const participantSnap = await participantRef.get();

      if (participantSnap.exists) {
        const userSnap = await userRef.get();
        const user = userSnap.data() || {};
        await participantRef.update({
          displayName,
          phoneNumber: user.phoneNumber || null,
        });
      }
    })
  );

  return {
    displayName,
  };
});



// Refreshes the signed-in user's current face descriptor in every event roster.
// Called immediately after Face Setup is saved so existing trips do not keep an
// obsolete descriptor snapshot.
exports.refreshMyFaceProfile = onCall(async (request) => {
  const uid = requireAuth(request);

  const userRef = db.doc(`users/${uid}`);
  const profileRef = db.doc(`users/${uid}/faceProfile/current`);

  const [userSnap, profileSnap, eventRefsSnap] = await Promise.all([
    userRef.get(),
    profileRef.get(),
    userRef.collection("eventRefs").get(),
  ]);

  if (!userSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Your SnapLoop user profile is missing."
    );
  }

  if (!profileSnap.exists) {
    throw new HttpsError(
      "failed-precondition",
      "Face setup is missing."
    );
  }

  const user = userSnap.data() || {};
  const profile = profileSnap.data() || {};

  if (!Array.isArray(profile.embedding) || profile.embedding.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "Face setup is incomplete."
    );
  }

  const writer = db.batch();
  let updated = 0;

  for (const eventRefDoc of eventRefsSnap.docs) {
    const eventId = eventRefDoc.id;
    const participantRef = db.doc(
      `events/${eventId}/participants/${uid}`
    );
    const memberRef = db.doc(
      `events/${eventId}/members/${uid}`
    );

    const [participantSnap, memberSnap] = await Promise.all([
      participantRef.get(),
      memberRef.get(),
    ]);

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
      writer.update(memberRef, {
        faceTemplateVersion: Number(profile.version || 1),
      });
    }
  }

  if (updated > 0) {
    await writer.commit();
  }

  return {
    updated,
    version: Number(profile.version || 1),
  };
});


// Refreshes participant identity snapshots for one event. Any event member can
// call it; the Admin SDK reads private user documents and only copies the
// roster-facing display name + phone number into that event's participant docs.
exports.syncEventRosterIdentities = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");

  const memberRef = db.doc(`events/${eventId}/members/${uid}`);
  const memberSnap = await memberRef.get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "Join this event first.");
  }

  const participantsSnap = await db
    .collection(`events/${eventId}/participants`)
    .get();

  const writer = db.batch();
  let updated = 0;

  for (const participantDoc of participantsSnap.docs) {
    const userId = participantDoc.id;
    const userSnap = await db.doc(`users/${userId}`).get();
    if (!userSnap.exists) continue;
    const user = userSnap.data() || {};

    writer.update(participantDoc.ref, {
      displayName: user.displayName || null,
      phoneNumber: user.phoneNumber || null,
    });
    updated += 1;
  }

  if (updated > 0) await writer.commit();
  return { updated };
});

function photoDocumentId(matchId) {
  return Buffer.from(matchId, "utf8").toString("base64url");
}

// A participant can dismiss only their own appearance. This trusted function
// updates both the appearance record and the query-friendly matchedUserIds.
exports.dismissAppearance = onCall(async (request) => {
  const uid = requireAuth(request);
  const data = request.data || {};
  const eventId = requireString(data.eventId, "eventId");
  const matchId = requireString(data.matchId, "matchId");
  const participantUserId = requireString(
    data.participantUserId,
    "participantUserId"
  );

  if (participantUserId !== uid) {
    throw new HttpsError(
      "permission-denied",
      "You can only dismiss your own appearance."
    );
  }

  const memberSnap = await db.doc(`events/${eventId}/members/${uid}`).get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "Join this event first.");
  }

  const photoRef = db.doc(
    `events/${eventId}/photos/${photoDocumentId(matchId)}`
  );

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(photoRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", "That photo no longer exists.");
    }

    const photo = snap.data() || {};
    const appearances = Array.isArray(photo.appearances)
      ? photo.appearances.map((appearance) => {
          if (appearance.participantUserId !== uid) return appearance;
          return { ...appearance, dismissedByUser: true };
        })
      : [];

    const matchedUserIds = Array.isArray(photo.matchedUserIds)
      ? photo.matchedUserIds.filter((userId) => userId !== uid)
      : [];

    tx.update(photoRef, { appearances, matchedUserIds });
  });

  return { dismissed: true };
});

// Removes a member and their event-scoped embedding.
exports.leaveEvent = onCall(async (request) => {
  const actorUid = requireAuth(request);
  const data = request.data || {};

  const eventId = requireString(data.eventId, "eventId");
  const targetUid = requireString(data.userId || actorUid, "userId");

  const eventRef = db.doc(`events/${eventId}`);
  const actorMemberRef = db.doc(`events/${eventId}/members/${actorUid}`);
  const targetMemberRef = db.doc(`events/${eventId}/members/${targetUid}`);
  const participantRef = db.doc(`events/${eventId}/participants/${targetUid}`);
  const eventRefForUser = db.doc(`users/${targetUid}/eventRefs/${eventId}`);

  try {
    await db.runTransaction(async (tx) => {
      const [eventSnap, actorSnap, targetSnap] = await Promise.all([
        tx.get(eventRef),
        tx.get(actorMemberRef),
        tx.get(targetMemberRef),
      ]);

      if (!eventSnap.exists) {
        throw new HttpsError(
          "not-found",
          "This event does not exist."
        );
      }

      if (!targetSnap.exists) {
        return;
      }

      const actorRole = actorSnap.exists ? actorSnap.data().role : null;
      const canRemove =
        actorUid === targetUid || actorRole === "organizer";

      if (!canRemove) {
        throw new HttpsError(
          "permission-denied",
          "You cannot remove this member."
        );
      }

      if (
        actorUid === targetUid &&
        targetSnap.data().role === "organizer"
      ) {
        throw new HttpsError(
          "failed-precondition",
          "The organizer cannot leave this event yet."
        );
      }

      const event = eventSnap.data();
      const count = Math.max(0, Number(event.memberCount || 1) - 1);

      tx.delete(targetMemberRef);
      tx.delete(participantRef);
      tx.delete(eventRefForUser);
      tx.update(eventRef, { memberCount: count });
    });

    return {
      eventId,
      userId: targetUid,
    };
  } catch (error) {
    if (error instanceof HttpsError) {
      throw error;
    }
    console.error("leaveEvent failed", error);
    throw new HttpsError(
      "internal",
      "Could not leave the event."
    );
  }
});
