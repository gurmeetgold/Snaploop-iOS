// Keep existing production functions and layer MVP management/invite functions
// beside them. Requiring index.js initializes firebase-admin once.
Object.assign(exports, require("./index"));
Object.assign(exports, require("./invites"));
Object.assign(exports, require("./eventManagement"));
