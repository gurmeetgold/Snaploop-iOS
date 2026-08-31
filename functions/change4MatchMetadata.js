function recordMap(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? { ...value } : {};
}

function normalizedUserId(value) {
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
    matchedFaceIdentityIds: recordMap(data.matchedFaceIdentityIds),
    matchedProfileRevisions: recordMap(data.matchedProfileRevisions),
    matchedMembershipIds: recordMap(data.matchedMembershipIds),
  };
}

function isRecipientDismissed(state, userId) {
  return !!state && state.dismissedUserIds instanceof Set && state.dismissedUserIds.has(userId);
}

function upsertActiveAppearance(state, {
  participantUserId,
  confidence,
  faceIdentityId,
  faceProfileRevision,
  recipientMembershipId = null,
}) {
  const userId = normalizedUserId(participantUserId);
  if (!userId || isRecipientDismissed(state, userId)) return false;

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

  return {
    appearances,
    matchedUserIds: activeUserIds,
    matchedFaceIdentityIds: state.matchedFaceIdentityIds,
    matchedProfileRevisions: state.matchedProfileRevisions,
    matchedMembershipIds: state.matchedMembershipIds,
    dismissedUserIds: [...state.dismissedUserIds].sort(),
  };
}

function dismissRecipientMatchMetadata(data, userId) {
  const normalized = normalizedUserId(userId);
  if (!normalized) throw new TypeError("userId is required");
  const state = prepareIncrementalMatchState(data);
  state.appearanceByUser.delete(normalized);
  state.dismissedUserIds.add(normalized);
  delete state.matchedFaceIdentityIds[normalized];
  delete state.matchedProfileRevisions[normalized];
  delete state.matchedMembershipIds[normalized];
  return finalizeIncrementalMatchState(state);
}

function removeRecipientMatchMetadata(data, userId, { removeDismissal = false } = {}) {
  const normalized = normalizedUserId(userId);
  if (!normalized) throw new TypeError("userId is required");
  const state = prepareIncrementalMatchState(data);
  state.appearanceByUser.delete(normalized);
  if (removeDismissal) state.dismissedUserIds.delete(normalized);
  delete state.matchedFaceIdentityIds[normalized];
  delete state.matchedProfileRevisions[normalized];
  delete state.matchedMembershipIds[normalized];
  return finalizeIncrementalMatchState(state);
}

module.exports = {
  dismissRecipientMatchMetadata,
  finalizeIncrementalMatchState,
  isRecipientDismissed,
  normalizedDismissedUserIds,
  prepareIncrementalMatchState,
  removeRecipientMatchMetadata,
  upsertActiveAppearance,
};
