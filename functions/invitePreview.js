const { onRequest } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const db = admin.firestore();

function clean(value) {
  return typeof value === "string" ? value.trim() : "";
}

exports.invitePreview = onRequest(async (request, response) => {
  response.set("Cache-Control", "private, max-age=60");
  if (request.method !== "GET") {
    response.status(405).json({ error: "method_not_allowed" });
    return;
  }

  const kind = clean(request.query.kind);
  const value = clean(request.query.value);
  if (!value || (kind !== "e" && kind !== "c")) {
    response.status(400).json({ error: "invalid_invite" });
    return;
  }

  try {
    const lookup = kind === "e"
      ? await db.doc(`inviteTokens/${value}`).get()
      : await db.doc(`joinCodes/${value.toUpperCase()}`).get();
    if (!lookup.exists) {
      response.status(404).json({ error: "invite_not_found" });
      return;
    }

    const eventId = clean(lookup.data()?.eventId);
    if (!eventId) {
      response.status(404).json({ error: "invite_not_found" });
      return;
    }

    const eventSnap = await db.doc(`events/${eventId}`).get();
    if (!eventSnap.exists) {
      response.status(404).json({ error: "event_not_found" });
      return;
    }

    const event = eventSnap.data() || {};
    const creatorUid = clean(event.creatorUserId);
    let inviterName = "A SnapLoop member";
    if (creatorUid) {
      const userSnap = await db.doc(`users/${creatorUid}`).get();
      const displayName = clean(userSnap.data()?.displayName);
      if (displayName) inviterName = displayName;
    }

    response.json({
      eventId,
      name: clean(event.name) || "SnapLoop Event",
      category: clean(event.category) || "event",
      startsAtMillis: event.startsAt?.toMillis ? event.startsAt.toMillis() : null,
      endsAtMillis: event.endsAt?.toMillis ? event.endsAt.toMillis() : null,
      inviterName,
      status: clean(event.status) || "active",
    });
  } catch (error) {
    console.error("invite preview failed", error);
    response.status(500).json({ error: "preview_unavailable" });
  }
});
