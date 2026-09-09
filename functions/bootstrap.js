// Single export surface for production callables.
//
// firebase-admin v13 no longer exposes Firestore value classes on the legacy
// admin.firestore namespace. A number of long-lived modules in this codebase
// still read Timestamp/FieldValue/FieldPath from that namespace. Install one
// explicit compatibility bridge before loading any implementation module so the
// production runtime is deterministic while those modules are migrated to the
// modular firebase-admin/firestore imports over time.
const admin = require("firebase-admin");
const { Timestamp, FieldValue, FieldPath } = require("firebase-admin/firestore");
Object.assign(admin.firestore, { Timestamp, FieldValue, FieldPath });

// Requiring index.js first initializes firebase-admin exactly once; legacy
// implementation modules are then used only for the specific handlers that
// remain authoritative. Security-sensitive aliases are overridden explicitly
// below so older installed clients cannot bypass current validation.
const legacy = require("./index");
const invites = require("./invites");
const inviteResolver = require("./inviteResolver");
const managed = require("./eventManagement");
const tripManager = require("./tripManager");
const profile = require("./profileManaged");
const leave = require("./leaveManaged");
const security = require("./security");
const memberCleanup = require("./memberCleanup");
const membershipIdentity = require("./membershipIdentity");
const notifications = require("./notifications");
const pushRegistration = require("./pushRegistration");
const inviteExpiry = require("./inviteExpiry");
const privacy = require("./privacyHardening");
const consentV5 = require("./biometricConsentV5");
const stableFaceIdentity = require("./stableFaceIdentity");
const faceIdentityMigration = require("./faceIdentityMigration");
const memberDirectory = require("./memberDirectory");
const memberPreferences = require("./memberPreferences");
const identityBoundMatches = require("./identityBoundMatches");
const change4MatchPublishing = require("./change4MatchPublishing");
const change4MemberActions = require("./change4MemberActions");
const change4FaceProfileCleanup = require("./change4FaceProfileCleanup");
const change4BiometricExpiry = require("./change4BiometricExpiry");
const faceErasure = require("./faceErasure");
const invitePreview = require("./invitePreview");

exports.createEvent = managed.createEventMVP;
exports.joinEvent = managed.joinEventManaged;
exports.resolveInvite = inviteResolver.resolveInviteCanonical;
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
exports.expirePendingInvites = inviteExpiry.expirePendingInvites;
exports.invitePreview = invitePreview.invitePreview;
exports.resolveInvitePreview = invitePreview.resolveInvitePreview;

exports.registerPushToken = pushRegistration.registerPushToken;
exports.unregisterPushToken = notifications.unregisterPushToken;
exports.deliverNotificationRecord = notifications.deliverNotificationRecord;

exports.syncMyUserProfile = security.syncMyUserProfile;
exports.updateDisplayName = security.updateDisplayNameTrusted;
exports.refreshMyFaceProfile = profile.refreshMyFaceProfileManaged;
exports.acceptBiometricConsent = consentV5.acceptBiometricConsent;
exports.ensureMyFaceIdentity = faceIdentityMigration.ensureMyFaceIdentity;
exports.saveMyFaceProfile = stableFaceIdentity.saveMyFaceProfile;
exports.eraseMyFaceProfile = faceErasure.eraseMyFaceProfileIdentityBound;
exports.withdrawBiometricConsent = faceErasure.withdrawBiometricConsentIdentityBound;
exports.deleteMyAccount = security.deleteMyAccount;
exports.listEventFaceProfiles = stableFaceIdentity.listEventFaceProfiles;
exports.listEventMembers = memberDirectory.listEventMembers;
exports.getMemberPhotoPreferences = memberPreferences.getMemberPhotoPreferences;
exports.setOwnPhotoVisibility = memberPreferences.setOwnPhotoVisibility;
exports.disableOwnMatchesEverywhere = memberPreferences.disableOwnMatchesEverywhere;
exports.listMyMatchedPhotos = identityBoundMatches.listMyMatchedPhotosIdentityBound;
exports.getMatchedThumbnail = identityBoundMatches.getMatchedThumbnailIdentityBound;
exports.scrubParticipantBiometrics = privacy.scrubParticipantBiometrics;
exports.scrubLegacyParticipantBiometrics = privacy.scrubLegacyParticipantBiometrics;
exports.purgeExpiredBiometricProfiles = change4BiometricExpiry.purgeExpiredBiometricProfiles;
exports.scrubMatchesOnFaceProfileChange = change4FaceProfileCleanup.scrubMatchesOnFaceProfileChange;

exports.setSharing = change4MemberActions.setSharingIdentityBound;
exports.publishMatch = change4MatchPublishing.publishMatchIdentityBound;
exports.dismissAppearance = change4MemberActions.dismissAppearanceIdentityBound;

exports.purgeDeletedTripPreviews = privacy.purgeDeletedTripPreviews;
exports.purgeExpiredTripPreviews = privacy.purgeExpiredTripPreviews;
exports.hardDeleteDeletedTrips = privacy.hardDeleteDeletedTrips;

exports.cleanupRemovedMemberPhotoData = memberCleanup.cleanupRemovedMemberPhotoData;
exports.assignMembershipIdentityOnCreate = membershipIdentity.assignMembershipIdentityOnCreate;
exports.syncEventRosterIdentities = legacy.syncEventRosterIdentities;
