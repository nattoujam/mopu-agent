#!/usr/bin/env node
// Nextcloud Talk の bot としてメッセージを送る。
// 使い方: notify.ts <設定ファイル> [--silent] <本文>
// 設定ファイルは {"url", "room", "secret"} の JSON
import { createHmac, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";

type Config = { url: string; room: string; secret: string };

const TIMEOUT_MS = 10_000;

function readConfig(path: string): Config {
  const data: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (typeof data !== "object" || data === null) throw new Error(`${path} が JSON オブジェクトではありません`);
  const { url, room, secret } = data as Record<string, unknown>;
  if (typeof url !== "string" || typeof room !== "string" || typeof secret !== "string") {
    throw new Error(`${path} に url / room / secret がありません`);
  }
  return { url: url.replace(/\/+$/, ""), room, secret };
}

// Talk は本文全体ではなく、random と message の値を連結したものの HMAC で bot を確かめるため
function sign(secret: string, random: string, message: string): string {
  return createHmac("sha256", secret).update(random + message).digest("hex");
}

async function send(config: Config, message: string, silent: boolean): Promise<void> {
  const random = randomBytes(32).toString("hex");
  const res = await fetch(`${config.url}/ocs/v2.php/apps/spreed/api/v1/bot/${encodeURIComponent(config.room)}/message`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "OCS-APIRequest": "true",
      "X-Nextcloud-Talk-Bot-Random": random,
      "X-Nextcloud-Talk-Bot-Signature": sign(config.secret, random, message),
    },
    body: JSON.stringify({ message, silent }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
}

async function main(argv: string[]): Promise<void> {
  const [configPath, ...rest] = argv;
  const silent = rest.includes("--silent");
  const message = rest.filter((arg) => arg !== "--silent").join(" ");
  if (!configPath || !message) throw new Error("使い方: notify.ts <設定ファイル> [--silent] <本文>");
  await send(readConfig(configPath), message, silent);
}

main(process.argv.slice(2)).catch((e: unknown) => {
  // fetch の接続エラーは message が "fetch failed" だけで、原因は cause に入るため
  const cause = e instanceof Error && e.cause instanceof Error ? `: ${e.cause.message}` : "";
  console.error(e instanceof Error ? e.message + cause : String(e));
  process.exit(1);
});
