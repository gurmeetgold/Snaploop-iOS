// Keep the existing production functions untouched and layer new MVP invite
// functions beside them. Requiring index.js initializes firebase-admin once.
Object.assign(exports, require("./index"));
Object.assign(exports, require("./invites"));
