// Run the actual Go repair CLI against disposable Timescale and loopback Discord.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
const exec = promisify(execFile);
const dsn = process.env.TEST_DATABASE_URL;
assert.equal(process.env.CLASHKING_DISPOSABLE_TIMESCALE, "1");
assert.match(dsn ?? "", /^postgres:\/\/clashking_test:clashking_test@127\.0\.0\.1:\d+\/clashking_test\?sslmode=disable$/u);
const sql = async (query) => (await exec("psql", [dsn, "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", query])).stdout.trim();
const guild = "999999999999993901", app = "999999999999993902";
const parent = "999999999999993903", thread = "999999999999993904", other = "999999999999993905", failing = "999999999999993906";
const ids = [1,2,3,4,5].map(i => `00000000-0000-4000-8000-00000000390${i}`);
const hook = (channel, id) => ({ id, type: 1, guild_id: guild, channel_id: channel, user: { id: app }, token: "fixture" });
const hooks = new Map([[parent, [hook(parent, "999999999999993911")]]]);
let parentReads = 0, creates = 0, rejectedPosts = 0, failPost = true;
const provider = createServer((req, res) => {
  res.setHeader("content-type", "application/json");
  const send = (value, status = 200) => { res.statusCode = status; res.end(JSON.stringify(value)); };
  if (req.url === "/users/@me") return send({ id: app });
  const channel = /^\/channels\/(\d+)$/u.exec(req.url ?? "");
  if (channel) {
    if (channel[1] === parent && ++parentReads === 1) return send({ message: "temporary" }, 503);
    return send({ id: channel[1], guild_id: guild, type: channel[1] === thread ? 11 : 0, ...(channel[1] === thread ? { parent_id: parent } : {}) });
  }
  const list = /^\/channels\/(\d+)\/webhooks$/u.exec(req.url ?? "");
  if (list) {
    if (req.method === "POST") {
      if (list[1] === failing && failPost) { rejectedPosts++; return send({ message: "ambiguous failure" }, 503); }
      const h = hook(list[1], String(999999999999993920n + BigInt(creates++)));
      hooks.set(list[1], [h]); return send(h);
    }
    return send(hooks.get(list[1]) ?? []);
  }
  send({ message: "not found" }, 404);
});
await new Promise(resolve => provider.listen(0, "127.0.0.1", resolve));
const temporary = await mkdtemp(join(tmpdir(), "ck-reminder-repair-"));
const binary = join(temporary, "repair"), root = resolve("database");
try {
  await sql(`INSERT INTO servers(id,name) VALUES('${guild}','Repair fixture')`);
  for (const [i, channel] of [parent, thread, other, other].entries()) {
    await sql(`INSERT INTO reminders(id,server_id,type,type_name,clan_tag,webhook_token,channel_id,minutes_remaining) VALUES('${ids[i]}','${guild}',1,'War','#PYLQ','fixture','${channel}',${(i+1)*60})`);
  }
  await exec("go", ["build", "-o", binary, "migrations/reminder_webhooks.go"], { cwd: root });
  // The CLI discovers a workspace .env. Give it an owned empty workspace so
  // this check never depends on or reads a developer's private configuration.
  const working = join(temporary, "workspace", "database")
  await mkdir(join(working, "timescale"), { recursive: true })
  await writeFile(join(temporary, "workspace", ".env"), "")
  await writeFile(join(working, "timescale", "001_initial_stats.sql"), "")
  const env = { ...process.env, TIMESCALE_URL: dsn, BOT_TOKEN: "fixture", REMINDER_DISCORD_API_URL: `http://127.0.0.1:${provider.address().port}`, REMINDER_WEBHOOKS_APPLY: "0", REMINDER_WEBHOOKS_START_AT: "" };
  const run = (extra = {}) => exec(binary, [], { cwd: working, env: { ...env, ...extra } });
  const preview = await run();
  assert.match(preview.stdout, /apply=false scanned=4 total=4/u);
  assert(parentReads >= 2); assert.equal(creates, 0);
  assert.equal(await sql("SELECT count(*) FROM reminders WHERE webhook_id IS NOT NULL"), "0");
  await assert.rejects(run({ REMINDER_WEBHOOKS_START_AT: "00000000-0000-4000-8000-000000000001" }));
  const resumed = await run({ REMINDER_WEBHOOKS_APPLY: "1", REMINDER_WEBHOOKS_START_AT: ids[2] });
  assert.match(resumed.stdout, /scanned=2 total=2/u); assert.equal(creates, 1);
  assert.equal(await sql("SELECT count(*) FROM reminders WHERE webhook_id IS NOT NULL"), "2");
  await run({ REMINDER_WEBHOOKS_APPLY: "1" });
  assert.equal(creates, 1);
  assert.equal(await sql("SELECT count(*) FROM reminders WHERE webhook_id IS NOT NULL AND webhook_token=''"), "4");
  assert.equal(await sql(`SELECT channel_id||':'||thread_id FROM reminders WHERE id='${ids[1]}'`), `${parent}:${thread}`);
  await sql(`INSERT INTO reminders(id,server_id,type,type_name,clan_tag,webhook_token,channel_id,minutes_remaining) VALUES('${ids[4]}','${guild}',1,'War','#PYLQ','fixture','${failing}',300)`);
  await assert.rejects(run({ REMINDER_WEBHOOKS_APPLY: "1", REMINDER_WEBHOOKS_START_AT: ids[4] }));
  assert.equal(rejectedPosts, 1); assert.equal(creates, 1);
  assert.equal(await sql(`SELECT webhook_id IS NULL FROM reminders WHERE id='${ids[4]}'`), "t");
  failPost = false;
  await run({ REMINDER_WEBHOOKS_APPLY: "1", REMINDER_WEBHOOKS_START_AT: ids[4] });
  await run({ REMINDER_WEBHOOKS_APPLY: "1" });
  assert.equal(creates, 2);
  console.log("PASS actual reminder repair: safe GET retry, inclusive resume, shared/thread reuse, no ambiguous POST retry, repeat apply creates none");
} finally {
  await new Promise(resolve => provider.close(resolve));
  await rm(temporary, { recursive: true, force: true });
}
