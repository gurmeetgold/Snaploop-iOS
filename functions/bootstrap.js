// Single export surface for production callables.
// Requiring index.js first initializes firebase-admin exactly once; legacy
// implementation modules are then used only for the specific handlers that
// remain authoritative. Security-sensitive aliases are overridden explicitly
// below so older installed clients cannot bypass current validation.
const legacy = require("./index");
const invites = require("./invites");
const managed = require("./eventManagement");
const lifecycle = require("./lifecycle");
const profile = require("./profileManaged");
const leave = require("./leaveManaged");
const security = require("./security");
const memberCleanup = require("./memberCleanup");
const notifications = require("./notifications");
const privacy = require("./privacyHardening");

exports.createEvent = managed.createEventMVP;
exports.joinEvent = managed.joinEventManaged;
exports.resolveInvite = legacy.resolveInvite;
exports.updateEventManaged = managed.updateEventManaged;
exports.setEventStatus = lifecycle.setEventStatusManaged;
exports.manageEventMember = managed.manageEventMember;
exports.leaveEvent = leave.leaveEventManaged;

exports.inviteByPhone = managed.inviteByPhoneManaged;
exports.listEventInvites = managed.listEventInvitesManaged;
exports.nextPendingInvite = invites.nextPendingInvite;
exports.declineEventInvite = invites.declineEventInvite;
exports.revokeEventInvite = notifications.revokeEventInvite;
exports.notifyPendingInvite = notifications.notifyPendingInvite;
exports.markInviteJoined = notifications.markInviteJoined;
exports.hydrateDeferredInvites = notifications.hydrateDeferredInvites;
exports.expirePendingInvites = notifications.expirePendingInvites;

exports.registerPushToken = notifications.registerPushToken;
exports.unregisterPushToken = notifications.unregisterPushToken;
exports.deliverNotificationRecord = notifications.deliverNotificationRecord;

exports.syncMyUserProfile = security.syncMyUserProfile;
exports.updateDisplayName = security.updateDisplayNameTrusted;
exports.refreshMyFaceProfile = profile.refreshMyFaceProfileManaged;
exports.acceptBiometricConsent = privacy.acceptBiometricConsent;
exports.eraseMyFaceProfile = security.eraseMyFaceProfile;
exports.withdrawBiometricConsent = security.withdrawBiometricConsent;
exports.deleteMyAccount = security.deleteMyAccount;
exports.listEventFaceProfiles = privacy.listEventFaceProfiles;
exports.scrubParticipantBiometrics = privacy.scrubParticipantBiometrics;
exports.scrubLegacyParticipantBiometrics = privacy.scrubLegacyParticipantBiometrics;

exports.setSharing = security.setSharingManaged;
exports.publishMatch = security.publishMatch;
exports.dismissAppearance = security.dismissAppearanceTrusted;

exports.purgeDeletedTripPreviews = privacy.purgeDeletedTripPreviews;
exports.purgeExpiredTripPreviews = privacy.purgeExpiredTripPreviews;
exports.hardDeleteDeletedTrips = privacy.hardDeleteDeletedTrips;

exports.cleanupRemovedMemberPhotoData = memberCleanup.cleanupRemovedMemberPhotoData;
exports.syncEventRosterIdentities = legacy.syncEventRosterIdentities;
