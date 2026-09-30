import { mkdir, open as fsOpen, readFile, rename, stat, unlink } from "node:fs/promises";
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

export class StoreError extends Error {}

/**
 * Durable device store: one JSON file in a dedicated 0700 directory.
 *
 * Mutations are serialized. Each builds the next state from the committed state,
 * writes it (0600 temp file, fsync, rename) and swaps it into memory after the
 * rename (the commit point). A failure before the rename leaves memory and disk
 * unchanged so callers can report the error and retry. The directory fsync after
 * the rename is best effort and reported via onDurabilityWarning.
 */
export class DeviceStore {
  private devices = new Map<string, DeviceRecord>();
  private chain: Promise<unknown> = Promise.resolve();
  private readonly file: string;
  private readonly dir: string;
  private readonly key: Buffer;

  constructor(file: string, key: Buffer) {
    this.file = file;
    this.dir = path.dirname(file);
    this.key = key;
  }

  async load(): Promise<void> {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    // Do not chmod an arbitrary existing directory: require it to already be private.
    const st = await stat(this.dir);
    if ((st.mode & 0o077) !== 0) {
      throw new StoreError(`data directory ${this.dir} must not be group/world accessible (chmod 700 it)`);
    }
    if (typeof process.getuid === "function" && st.uid !== process.getuid()) {
      throw new StoreError(`data directory ${this.dir} must be owned by the service user`);
    }
    let raw: string;
    try {
      raw = await readFile(this.file, "utf8");
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return;
      throw e;
    }
    const fst = await stat(this.file);
    if ((fst.mode & 0o077) !== 0) throw new StoreError(`${this.file} must be mode 0600`);
    const parsed = JSON.parse(raw) as FileShape;
    if (parsed.version !== 1 || typeof parsed.devices !== "object") throw new StoreError("unsupported store format");
    for (const rec of Object.values(parsed.devices)) this.devices.set(rec.deviceId, rec);
  }

  get(deviceId: string): DeviceRecord | undefined {
    return this.devices.get(deviceId);
  }

  refreshToken(rec: DeviceRecord): string {
    return unseal(this.key, rec.refreshToken, rec.deviceId);
  }

  add(deviceId: string, credentialHash: string, refreshToken: string, scope: string): Promise<void> {
    return this.mutate((next) => {
      next.set(deviceId, {
        deviceId,
        credentialHash,
        refreshToken: seal(this.key, refreshToken, deviceId),
        scope,
        createdAt: new Date().toISOString(),
      });
      return true;
    }).then(() => undefined);
  }

  /** Replace refresh token if Google rotated it, only if the device still exists. */
  rotate(deviceId: string, refreshToken: string): Promise<void> {
    return this.mutate((next) => {
      const rec = next.get(deviceId);
      if (!rec) return false;
      next.set(deviceId, { ...rec, refreshToken: seal(this.key, refreshToken, deviceId) });
      return true;
    }).then(() => undefined);
  }

  /** Resolves true if removed. Rejects (record retained) if the write fails. */
  remove(deviceId: string): Promise<boolean> {
    return this.mutate((next) => next.delete(deviceId));
  }

  private mutate(fn: (next: Map<string, DeviceRecord>) => boolean): Promise<boolean> {
    const run = async () => {
      const next = new Map(this.devices);
      if (!fn(next)) return false;
      await this.write(next);
      this.devices = next;
      return true;
    };
    const p = this.chain.then(run, run);
    this.chain = p.catch(() => {});
    return p;
  }

  private async write(devices: Map<string, DeviceRecord>): Promise<void> {
    const data: FileShape = { version: 1, devices: Object.fromEntries(devices) };
    const tmp = `${this.file}.${process.pid}.tmp`;
    await unlink(tmp).catch(() => {});
    try {
      const fh = await fsOpen(tmp, "wx", 0o600);
      try {
        await fh.writeFile(JSON.stringify(data));
        await fh.sync();
      } finally {
        await fh.close();
      }
      await rename(tmp, this.file);
    } catch (e) {
      await unlink(tmp).catch(() => {});
      throw e;
    }
    // Commit point is the rename. A directory fsync failure after it means the new
    // state is visible but durability across a crash is unknown: log loudly, but do
    // not report the mutation as failed (memory must match the visible file).
    try {
      const dh = await fsOpen(this.dir, "r");
      try {
        await dh.sync();
      } finally {
        await dh.close();
      }
    } catch {
      this.onDurabilityWarning?.();
    }
  }

  /** Invoked when the post-rename directory fsync fails (filesystem may not support it). */
  onDurabilityWarning?: () => void;
}
