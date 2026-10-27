import { deepStrictEqual, match, rejects, strictEqual } from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHmac } from "node:crypto";
import { mkdtempSync, writeFileSync } from "node:fs";
import { createServer, type IncomingHttpHeaders } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, beforeEach, describe, it } from "node:test";
import { promisify } from "node:util";

const ENTRY = join(import.meta.dirname, "..", "lib", "notify.ts");
const SECRET = "test-secret-0123456789";
const ROOM = "abc123";

type Received = { url: string; headers: IncomingHttpHeaders; body: Record<string, unknown> };
type Reply = { status: number; body: string };

const received: Received[] = [];
let replies: Reply[] = [];
let baseUrl = "";

const server = createServer((req, res) => {
  let raw = "";
  req.on("data", (chunk: Buffer) => (raw += chunk.toString()));
  req.on("end", () => {
    received.push({ url: req.url ?? "", headers: req.headers, body: JSON.parse(raw) as Record<string, unknown> });
    const reply = replies.shift() ?? { status: 201, body: "{}" };
    res.writeHead(reply.status, { "Content-Type": "application/json" }).end(reply.body);
  });
});

function configFile(): string {
  const file = join(mkdtempSync(join(tmpdir(), "notify-test-")), "nextcloud.json");
  writeFileSync(file, JSON.stringify({ url: `${baseUrl}/`, room: ROOM, secret: SECRET }));
  return file;
}

async function notify(...args: string[]): Promise<void> {
  await promisify(execFile)("node", [ENTRY, configFile(), ...args]);
}

before(async () => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(() => {
  server.close();
});

beforeEach(() => {
  received.length = 0;
  replies = [];
});

describe("notify.ts", () => {
  it("random と message の HMAC を署名に付けて、会話の bot API に送る", async () => {
    await notify("--silent", "テスト", "の本文");
    strictEqual(received.length, 1);
    const [req] = received;
    strictEqual(req?.url, `/ocs/v2.php/apps/spreed/api/v1/bot/${ROOM}/message`);
    strictEqual(req?.headers["ocs-apirequest"], "true");
    deepStrictEqual(req?.body, { message: "テスト の本文", silent: true });
    const random = String(req?.headers["x-nextcloud-talk-bot-random"]);
    const expected = createHmac("sha256", SECRET).update(random + "テスト の本文").digest("hex");
    strictEqual(req?.headers["x-nextcloud-talk-bot-signature"], expected);
  });

  it("送れなかったら、ステータスを stderr に出して 1 で終わる", async () => {
    replies = [{ status: 401, body: "unauthorized" }];
    await rejects(notify("届かない"), (e: { code?: number; stderr?: string }) => {
      strictEqual(e.code, 1);
      match(e.stderr ?? "", /HTTP 401/);
      return true;
    });
  });
});
