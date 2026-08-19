// Compatibility aliases: existing installed builds may still call these legacy
// callable names. Export the trusted MVP handlers under those names as well so
// date validation, Admin authorization and join notifications cannot be bypassed
// simply by using an older client.
const managed = require("./eventManagement");

exports.createEvent = managed.createEventMVP;
exports.joinEvent = managed.joinEventManaged;
exports.inviteByPhone = managed.inviteByPhoneManaged;
exports.listEventInvites = managed.listEventInvitesManaged;
