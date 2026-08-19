// Keep existing production functions and layer MVP management/invite functions
// beside them. Requiring index.js initializes firebase-admin once.
Object.assign(exports, require("./index"));
Object.assign(exports, require("./invites"));
Object.assign(exports, require("./eventManagement"));
// Must be last: older installed clients keep their callable names but receive
// the same hardened validation/authorization as the new handlers.
Object.assign(exports, require("./secureOverrides"));
