// Single export surface for production callables.
// Requiring index.js first initializes firebase-admin exactly once; legacy
// implementation modules are then used only for the specific handlers that
// remain authoritative. Security-sensitive aliases are overridden explicitly
// below so older installed clients cannot bypass current validation.
const legacy = require("./index");
const invites = require("./invites");
const managed = require("./eventManagement");
const tripManager = require("./tripManager");
const profile = require("./profileManaged");
const leave = require("./leaveManaged");
const security = require("./security");
const memberCleanup = require("./memberCleanup");
const notifications = require("./notifications");
const privacy = require("./privacyHardening");
const memberDirectory = require("./memberDirectory");
const memberPreferences = require("./memberPreferences");
const identityBoundMatches = require("./identityBoundMatches");
const invitePreview = require("./invitePreview");

exports.createEvent = managed.createEventMVP;
exports.joinEvent = managed.joinEventManaged;
exports.resolveInvite = legacy.resolveInvite;
exports.updateEventManaged = tripManager.updateTripManaged;
exports.setEventStatus = tripManager.setTripStatusManaged;
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
exports.invitePreview = invitePreview.invitePreview;

exports.registerPushToken = notifications.registerPushToken;
exports.unregisterPushToken = notifications.unregisterPushToken;
exports.deliverNotificationRecord = notifications.deliverNotificationRecord;

exports.syncMyUserProfile = security.syncMyUserProfile;
exports.updateDisplayName = security.updateDisplayNameTrusted;
exports.refreshMyFaceProfile = profile.refreshMyFaceProfileManaged;
exports.acceptBiometricConsent = privacy.acceptBiometricConsent;
exports.saveMyFaceProfile = privacy.saveMyFaceProfile;
exports.eraseMyFaceProfile = security.eraseMyFaceProfile;
exports.withdrawBiometricConsent = security.withdrawBiometricConsent;
exports.deleteMyAccount = security.deleteMyAccount;
exports.listEventFaceProfiles = privacy.listEventFaceProfiles;
exports.listEventMembers = memberDirectory.listEventMembers;
exports.getMemberPhotoPreferences = memberPreferences.getMemberPhotoPreferences;
exports.setOwnPhotoVisibility = memberPreferences.setOwnPhotoVisibility;
exports.listMyMatchedPhotos = identityBoundMatches.listMyMatchedPhotosIdentityBound;
exports.scrubParticipantBiometrics = privacy.scrubParticipantBiometrics;
exports.scrubLegacyParticipantBiometrics = privacy.scrubLegacyParticipantBiometrics;
exports.purgeExpiredBiometricProfiles = privacy.purgeExpiredBiometricProfiles;
exports.scrubMatchesOnFaceProfileChange = identityBoundMatches.scrubMatchesOnFaceProfileChange;

exports.setSharing = security.setSharingManaged;
exports.publishMatch = identityBoundMatches.publishMatchIdentityBound;
exports.dismissAppearance = security.dismissAppearanceTrusted;

exports.purgeDeletedTripPreviews = privacy.purgeDeletedTripPreviews;
exports.purgeExpiredTripPreviews = privacy.purgeExpiredTripPreviews;
exports.hardDeleteDeletedTrips = privacy.hardDeleteDeletedTrips;

exports.cleanupRemovedMemberPhotoData = memberCleanup.cleanupRemovedMemberPhotoData;
exports.syncEventRosterIdentities = legacy.syncEventRosterIdentities;
