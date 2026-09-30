import { mkdir, open as fsOpen, readFile, rename, chmod } from "node:fs/promises";
import path from "node:path";
import { open as unseal, seal, type Sealed } from "./secrets.ts";

export interface DeviceRecord {
  deviceId: string;
  credentialHash: string;
  refreshToken: Sealed; // AES-256-GCM, AAD = deviceId
  scope: string;
  createdAt: string;
}

interface FileShape {
  version: 1;
  devices: Record<string, DeviceRecord>;
}

/**
 * Durable device store. Single JSON file, rewritten atomically (write 0600 temp,
 * fsync, rename). Writes are serialized through a promise chain so concurrent
 * mutations cannot lose updates.
 */
export class DeviceStore {
  private devices = new Map<string, DeviceRecord>();
  private chain: Promise<void> = Promise.resolve();
  private readonly file: string;
  private readonly key: Buffer;

  constructor(file: string, key: Buffer) {
    this.file = file;
    this.key = key;
  }

  async load(): Promise<void> {
    await mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    await chmod(path.dirname(this.file), 0o700);
    let raw: string;
    try {
      raw = await readFile(this.file, "utf8");
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return;
      throw e;
    }
    const parsed = JSON.parse(raw) as FileShape;
    if (parsed.version !== 1 || typeof parsed.devices !== "object") throw new Error("unsupported store format");
    for (const rec of Object.values(parsed.devices)) this.devices.set(rec.deviceId, rec);
  }

  get(deviceId: string): DeviceRecord | undefined {
    return this.devices.get(deviceId);
  }

  refreshToken(rec: DeviceRecord): string {
    return unseal(this.key, rec.refreshToken, rec.deviceId);
  }

  async add(deviceId: string, credentialHash: string, refreshToken: string, scope: string): Promise<void> {
    const rec: DeviceRecord = {
      deviceId,
      credentialHash,
      refreshToken: seal(this.key, refreshToken, deviceId),
      scope,
      createdAt: new Date().toISOString(),
    };
    this.devices.set(deviceId, rec);
    await this.persist();
  }

  /** Replace refresh token if Google rotated it, only if device still exists. */
  async rotate(deviceId: string, refreshToken: string): Promise<void> {
    const rec = this.devices.get(deviceId);
    if (!rec) return;
    rec.refreshToken = seal(this.key, refreshToken, deviceId);
    await this.persist();
  }

  async remove(deviceId: string): Promise<boolean> {
    const existed = this.devices.delete(deviceId);
    if (existed) await this.persist();
    return existed;
  }

  private persist(): Promise<void> {
    const next = this.chain.then(() => this.writeNow());
    this.chain = next.catch(() => {});
    return next;
  }

  private async writeNow(): Promise<void> {
    const data: FileShape = { version: 1, devices: Object.fromEntries(this.devices) };
    const tmp = `${this.file}.${process.pid}.tmp`;
    const fh = await fsOpen(tmp, "w", 0o600);
    try {
      await fh.writeFile(JSON.stringify(data));
      await fh.sync();
    } finally {
      await fh.close();
    }
    await chmod(tmp, 0o600);
    await rename(tmp, this.file);
  }
}
