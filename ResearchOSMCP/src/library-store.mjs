import { appendFile, mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

const APPLE_REFERENCE_OFFSET_SECONDS = 978307200;
let mutationQueue = Promise.resolve();

export function defaultLibraryPath() {
  return process.env.RESEARCHOS_LIBRARY_PATH
    ?? join(homedir(), "Library", "Application Support", "ResearchOS", "library.json");
}

export function appleReferenceDateNow() {
  return Date.now() / 1000 - APPLE_REFERENCE_OFFSET_SECONDS;
}

export function makeID() {
  return randomUUID().toUpperCase();
}

export async function readLibrary(path = defaultLibraryPath()) {
  const raw = await readFile(path, "utf8");
  const library = JSON.parse(raw);
  library.questions ??= [];
  library.papers ??= [];
  library.markdownDocuments ??= [];
  return library;
}

async function safeStat(path) {
  try {
    return await stat(path);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function atomicWrite(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporaryPath = `${path}.mcp-${process.pid}-${randomUUID()}`;
  await writeFile(temporaryPath, JSON.stringify(value), { encoding: "utf8", mode: 0o600 });
  await rename(temporaryPath, path);
}

async function appendAudit(path, action, details) {
  const auditPath = join(dirname(path), "mcp-audit.jsonl");
  const record = {
    timestamp: new Date().toISOString(),
    action,
    details,
  };
  try {
    await appendFile(auditPath, `${JSON.stringify(record)}\n`, { encoding: "utf8", mode: 0o600 });
  } catch {
    // The ResearchOS write has already succeeded. Audit logging is best-effort.
  }
}

async function performUpdate(path, action, details, mutate) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const before = await safeStat(path);
    const library = before ? await readLibrary(path) : { questions: [], papers: [], markdownDocuments: [] };
    const result = await mutate(library);
    const latest = await safeStat(path);
    const changedDuringRead = Boolean(before && latest && before.mtimeMs !== latest.mtimeMs);
    if (changedDuringRead) continue;
    await atomicWrite(path, library);
    await appendAudit(path, action, details);
    return result;
  }
  throw new Error("ResearchOS 数据刚刚被其他操作修改，请重试一次。");
}

export function updateLibrary({ path = defaultLibraryPath(), action, details = {}, mutate }) {
  const work = () => performUpdate(path, action, details, mutate);
  const result = mutationQueue.then(work, work);
  mutationQueue = result.then(() => undefined, () => undefined);
  return result;
}

export function normalizeText(value, maxLength = 100_000) {
  return String(value ?? "").replace(/\r\n?/g, "\n").trim().slice(0, maxLength);
}
