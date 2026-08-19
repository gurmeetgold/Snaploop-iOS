// Compatibility aliases: existing installed builds may still call these legacy
// callable names. Export the trusted MVP handlers under those names as well so
// validation, Admin authorization and current user-facing copy cannot be bypassed
// simply by using an older client.
const managed = require("./eventManagement");
const profile = require("./profileManaged");
const leave = require("./leaveManaged");

exports.createEvent = managed.createEventMVP;
exports.joinEvent = managed.joinEventManaged;
exports.leaveEvent = leave.leaveEventManaged;
exports.inviteByPhone = managed.inviteByPhoneManaged;
exports.listEventInvites = managed.listEventInvitesManaged;
exports.refreshMyFaceProfile = profile.refreshMyFaceProfileManaged;
