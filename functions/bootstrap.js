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

// Event lifecycle + invite resolution.
exports.createEvent = managed.createEventMVP;
exports.joinEvent = managed.joinEventManaged;
exports.resolveInvite = legacy.resolveInvite;
exports.updateEventManaged = managed.updateEventManaged;
exports.setEventStatus = lifecycle.setEventStatusManaged;
exports.manageEventMember = managed.manageEventMember;
exports.leaveEvent = leave.leaveEventManaged;

// Invitations.
exports.inviteByPhone = managed.inviteByPhoneManaged;
exports.listEventInvites = managed.listEventInvitesManaged;
exports.nextPendingInvite = invites.nextPendingInvite;
exports.declineEventInvite = invites.declineEventInvite;

// Server-owned identity/profile operations.
exports.syncMyUserProfile = security.syncMyUserProfile;
exports.updateDisplayName = security.updateDisplayNameTrusted;
exports.refreshMyFaceProfile = profile.refreshMyFaceProfileManaged;
exports.eraseMyFaceProfile = security.eraseMyFaceProfile;
exports.withdrawBiometricConsent = security.withdrawBiometricConsent;
exports.deleteMyAccount = security.deleteMyAccount;

// Server-owned sharing + photo metadata operations.
exports.setSharing = security.setSharingManaged;
exports.publishMatch = security.publishMatch;
exports.dismissAppearance = security.dismissAppearanceTrusted;

// Membership deletion is defense-in-depth: every removal path, including role
// management and future trusted admin flows, scrubs that member's event photo
// appearances and authored shared previews.
exports.cleanupRemovedMemberPhotoData = memberCleanup.cleanupRemovedMemberPhotoData;

// Roster snapshots are still read/rewritten by a trusted callable; no direct
// client write permission is granted to participant documents.
exports.syncEventRosterIdentities = legacy.syncEventRosterIdentities;
