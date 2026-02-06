import { Database } from "bun:sqlite";

const db = new Database("pds.db", { create: true, strict: true });
db.exec("PRAGMA journal_mode=WAL");
db.exec("PRAGMA foreign_keys=ON");

const schema = await Bun.file(import.meta.dir + "/schema.sql").text();
db.exec(schema);

console.log("attributes:");
console.table(db.query("SELECT * FROM attributes").all());

console.log("\neva_current:");
console.table(db.query("SELECT * FROM eva_current").all());
