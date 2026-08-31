function recordMap(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? { ...value } : {};
}

function normalizedUserId(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function normalizedMembershipId(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function normalizedDismissedUserIds(data) {
  const values = new Set();
  const raw = data && Array.isArray(data.dismissedUserIds) ? data.dismissedUserIds : [];
  for (const value of raw) {
    const userId = normalizedUserId(value);
    if (userId) values.add(userId);
  }

  // Migrate the legacy representation opportunistically. Older documents kept a
  // dismissed appearance row with dismissedByUser=true. Change 4 now keeps the
  // opt-out as a minimal user-id tombstone instead, so a later incremental match
  // can never silently resurrect a photo the recipient dismissed.
  const appearances = data && Array.isArray(data.appearances) ? data.appearances : [];
  for (const appearance of appearances) {
    const userId = normalizedUserId(appearance && appearance.participantUserId);
    if (userId && appearance.dismissedByUser === true) values.add(userId);
  }
  return values;
}

function prepareIncrementalMatchState(existingPhoto) {
  const data = existingPhoto && typeof existingPhoto === "object" ? existingPhoto : {};
  const dismissedUserIds = normalizedDismissedUserIds(data);
  const appearanceByUser = new Map();

  const appearances = Array.isArray(data.appearances) ? data.appearances : [];
  for (const appearance of appearances) {
    const userId = normalizedUserId(appearance && appearance.participantUserId);
    if (!userId || appearance.dismissedByUser === true || dismissedUserIds.has(userId)) continue;
    appearanceByUser.set(userId, { ...appearance, participantUserId: userId, dismissedByUser: false });
  }

  return {
    appearanceByUser,
    dismissedUserIds,
    dismissedMembershipIds: recordMap(data.dismissedMembershipIds),
    matchedFaceIdentityIds: recordMap(data.matchedFaceIdentityIds),
    matchedProfileRevisions: recordMap(data.matchedProfileRevisions),
    matchedMembershipIds: recordMap(data.matchedMembershipIds),
  };
}

function recipientDismissalApplies(state, userId, membershipId = null) {
  if (!state || !(state.dismissedUserIds instanceof Set) || !state.dismissedUserIds.has(userId)) return false;
  const bound = normalizedMembershipId(state.dismissedMembershipIds[userId]);
  const current = normalizedMembershipId(membershipId);

  // A generation-bound dismissal belongs only to the participation in which the
  // user made it. If they leave and later rejoin, the new membership is allowed
  // to receive a fresh match. Legacy unbound dismissals fail closed and persist.
  if (bound && current && bound !== current) {
    state.dismissedUserIds.delete(userId);
    delete state.dismissedMembershipIds[userId];
    return false;
  }
  return true;
}

function upsertActiveAppearance(state, {
  participantUserId,
  confidence,
  faceIdentityId,
  faceProfileRevision,
  recipientMembershipId = null,
}) {
  const userId = normalizedUserId(participantUserId);
  if (!userId || recipientDismissalApplies(state, userId, recipientMembershipId)) return false;

  const appearance = {
    participantUserId: userId,
    confidence,
    faceIdentityId,
    faceProfileRevision,
    dismissedByUser: false,
  };
  if (recipientMembershipId) appearance.recipientMembershipId = recipientMembershipId;

  state.appearanceByUser.set(userId, appearance);
  state.matchedFaceIdentityIds[userId] = faceIdentityId;
  state.matchedProfileRevisions[userId] = faceProfileRevision;
  if (recipientMembershipId) state.matchedMembershipIds[userId] = recipientMembershipId;
  else delete state.matchedMembershipIds[userId];
  return true;
}

/// Removes only the currently active authorization for one recipient from a
/// prepared incremental state. Explicit dismissal tombstones are deliberately
/// preserved. This powers ambiguity/template re-evaluation where an old positive
/// is no longer valid, without accidentally undoing a recipient's "Not Me" choice.
function removeActiveAppearance(state, userId) {
  const normalized = normalizedUserId(userId);
  if (!normalized) throw new TypeError("userId is required");
  state.appearanceByUser.delete(normalized);
  delete state.matchedFaceIdentityIds[normalized];
  delete state.matchedProfileRevisions[normalized];
  delete state.matchedMembershipIds[normalized];
}

function finalizeIncrementalMatchState(state) {
  const activeUserIds = [...state.appearanceByUser.keys()]
    .filter((userId) => !state.dismissedUserIds.has(userId))
    .sort();
  const active = new Set(activeUserIds);

  const appearances = activeUserIds.map((userId) => ({
    ...state.appearanceByUser.get(userId),
    participantUserId: userId,
    dismissedByUser: false,
  }));

  for (const key of Object.keys(state.matchedFaceIdentityIds)) {
    if (!active.has(key)) delete state.matchedFaceIdentityIds[key];
  }
  for (const key of Object.keys(state.matchedProfileRevisions)) {
    if (!active.has(key)) delete state.matchedProfileRevisions[key];
  }
  for (const key of Object.keys(state.matchedMembershipIds)) {
    if (!active.has(key)) delete state.matchedMembershipIds[key];
  }
  for (const key of Object.keys(state.dismissedMembershipIds)) {
    if (!state.dismissedUserIds.has(key)) delete state.dismissedMembershipIds[key];
  }

  return {
    appearances,
    matchedUserIds: activeUserIds,
    matchedFaceIdentityIds: state.matchedFaceIdentityIds,
    matchedProfileRevisions: state.matchedProfileRevisions,
    matchedMembershipIds: state.matchedMembershipIds,
    dismissedUserIds: [...state.dismissedUserIds].sort(),
    dismissedMembershipIds: state.dismissedMembershipIds,
  };
}

function dismissRecipientMatchMetadata(data, userId, membershipId = null) {
  const normalized = normalizedUserId(userId);
  if (!normalized) throw new TypeError("userId is required");
  const state = prepareIncrementalMatchState(data);
  removeActiveAppearance(state, normalized);
  state.dismissedUserIds.add(normalized);
  const normalizedMembership = normalizedMembershipId(membershipId);
  if (normalizedMembership) state.dismissedMembershipIds[normalized] = normalizedMembership;
  else delete state.dismissedMembershipIds[normalized];
  return finalizeIncrementalMatchState(state);
}

function removeRecipientMatchMetadata(data, userId, { removeDismissal = false } = {}) {
  const normalized = normalizedUserId(userId);
  if (!normalized) throw new TypeError("userId is required");
  const state = prepareIncrementalMatchState(data);
  removeActiveAppearance(state, normalized);
  if (removeDismissal) {
    state.dismissedUserIds.delete(normalized);
    delete state.dismissedMembershipIds[normalized];
  }
  return finalizeIncrementalMatchState(state);
}

module.exports = {
  dismissRecipientMatchMetadata,
  finalizeIncrementalMatchState,
  normalizedDismissedUserIds,
  prepareIncrementalMatchState,
  recipientDismissalApplies,
  removeActiveAppearance,
  removeRecipientMatchMetadata,
  upsertActiveAppearance,
};
