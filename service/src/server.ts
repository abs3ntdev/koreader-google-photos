import { buildApp } from "./app.ts";
import { ConfigError, loadConfig } from "./config.ts";
import { GoogleOAuth } from "./google.ts";
import { PairingStore } from "./pairing.ts";
import { DeviceStore } from "./store.ts";

async function main() {
  let config;
  try {
    config = loadConfig();
  } catch (e) {
    if (e instanceof ConfigError) {
      console.error(`config error: ${e.message}`);
      process.exit(2);
    }
    throw e;
  }
  const devices = new DeviceStore(config.dataFile, config.encryptionKey);
  await devices.load();
  const pairings = new PairingStore(config.pairingTtlMs);
  setInterval(() => pairings.sweep(), 30_000).unref();
  const oauth = new GoogleOAuth({
    clientId: config.googleClientId,
    clientSecret: config.googleClientSecret,
    redirectUri: config.redirectUri,
  });
  const app = await buildApp({ config, oauth, devices, pairings, logger: true });
  await app.listen({ host: config.host, port: config.port });
  app.log.info(`public base ${config.publicBaseUrl.origin}, redirect URI ${config.redirectUri}`);
}

main().catch(() => {
  console.error("fatal startup error");
  process.exit(1);
});
