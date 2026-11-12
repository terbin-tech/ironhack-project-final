// Creates or updates the backend's DocumentDB user. Credentials come from the
// mounted secret files, never the command line.
const fs = require('fs');
const read = (name) => fs.readFileSync(`/mnt/secrets/${name}`, 'utf8').replace(/\r?\n$/, '');

const admin = db.getSiblingDB('admin');
admin.auth(read('master-username'), read('master-password'));

const user = read('app-username');
const pwd = read('app-password');
const roles = [{ role: 'readWrite', db: 'expensy' }];
if (admin.getUser(user)) {
  admin.updateUser(user, { pwd, roles });
} else {
  admin.createUser({ user, pwd, roles });
}
printjson(admin.getUser(user).roles);
