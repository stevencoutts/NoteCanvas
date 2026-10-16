// Reads and writes a NoteCanvas notebook folder: notebook.json, pages/<uuid>.json, assets/.
// The directory handle is remembered. Note text is never copied into localStorage.

import { decodeNotebook, decodePage, encodeNotebook, encodePage, assetName, addPage, addFolder, renameFolder, setTitle, setItemColor, dissolveFolder, removePage, moveItem, moveSection, flattenPages, findItem, emptyNotebook, emptyPage, sectionOf, uuid } from "./model.js";

const DB_NAME = "notecanvas";
const STORE = "kv";
const HANDLE_KEY = "lastNotebook";

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function idbSet(key, value) {
  const db = await openDB();
  await new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(value, key);
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  db.close();
}

async function idbGet(key) {
  const db = await openDB();
  const value = await new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readonly");
    const request = tx.objectStore(STORE).get(key);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  db.close();
  return value ?? null;
}

export async function rememberHandle(handle) {
  await idbSet(HANDLE_KEY, handle);
}

export async function rememberedHandle() {
  try {
    return await idbGet(HANDLE_KEY);
  } catch {
    return null;
  }
}

export async function forgetHandle() {
  await idbSet(HANDLE_KEY, null);
}

export function canPickDirectory() {
  return typeof window !== "undefined" && typeof window.showDirectoryPicker === "function";
}

export async function pickDirectory(id) {
  return window.showDirectoryPicker({ id, mode: "readwrite" });
}

export async function hasPermission(handle) {
  if (!handle?.queryPermission) return false;
  return (await handle.queryPermission({ mode: "readwrite" })) === "granted";
}

export async function requestPermission(handle) {
  if (!handle?.requestPermission) return false;
  return (await handle.requestPermission({ mode: "readwrite" })) === "granted";
}

async function findEntry(dir, name) {
  const wanted = name.toLowerCase();
  for await (const [entryName, handle] of dir.entries()) {
    if (entryName.toLowerCase() === wanted) return handle;
  }
  return null;
}

async function fileIn(dir, name, { create = false } = {}) {
  const existing = await findEntry(dir, name);
  if (existing?.kind === "file") return existing;
  if (create) return dir.getFileHandle(name, { create: true });
  const error = new Error(`Missing file ${name}`);
  error.name = "NotFoundError";
  throw error;
}

async function dirIn(dir, name, { create = false } = {}) {
  const existing = await findEntry(dir, name);
  if (existing?.kind === "directory") return existing;
  if (create) return dir.getDirectoryHandle(name, { create: true });
  const error = new Error(`Missing folder ${name}`);
  error.name = "NotFoundError";
  throw error;
}

async function readText(handle) {
  const file = await handle.getFile();
  return file.text();
}

async function writeText(handle, text) {
  const writable = await handle.createWritable();
  await writable.write(text);
  await writable.close();
}

async function writeBytes(handle, data) {
  const writable = await handle.createWritable();
  await writable.write(data);
  await writable.close();
}

export class Package {
  constructor(root, notebook) {
    this.root = root;
    this.notebook = notebook;
    this.chain = Promise.resolve();
  }

  enqueue(work) {
    const run = this.chain.then(work, work);
    this.chain = run.then(() => {}, () => {});
    return run;
  }

  static async open(root) {
    if (await findEntry(root, "keys.json")) {
      throw new Error("This notebook is encrypted. The web app cannot unlock it. Open it in NoteCanvas on the Mac.");
    }
    const manifest = await findEntry(root, "notebook.json");
    if (!manifest || manifest.kind !== "file") throw new Error("That folder is not a NoteCanvas notebook. It needs a notebook.json file.");
    let raw;
    try {
      raw = JSON.parse(await readText(manifest));
    } catch {
      throw new Error("notebook.json is damaged and could not be read.");
    }
    return new Package(root, decodeNotebook(raw));
  }

  static async create(parent, name) {
    const trimmed = name.trim().replace(/[\\/]/g, "") || "Untitled";
    const folderName = trimmed.toLowerCase().endsWith(".notebook") ? trimmed : `${trimmed}.notebook`;
    const display = folderName.replace(/\.notebook$/i, "");
    const existing = await findEntry(parent, folderName);
    if (existing) throw new Error(`“${folderName}” already exists in that folder.`);
    const root = await parent.getDirectoryHandle(folderName, { create: true });
    const notebook = emptyNotebook(display);
    const page = emptyPage("Untitled Page");
    const pkg = new Package(root, notebook);
    await pkg.writePage(page);
    addPage(notebook.sections[0], page, null);
    await pkg.writeManifest();
    return { pkg, page };
  }

  async writeManifest() {
    const handle = await fileIn(this.root, "notebook.json", { create: true });
    await writeText(handle, encodeNotebook(this.notebook));
  }

  async pageHandle(id, { create = false } = {}) {
    const pages = await dirIn(this.root, "pages", { create });
    return fileIn(pages, `${id}.json`, { create });
  }

  async writePage(page) {
    const handle = await this.pageHandle(page.id, { create: true });
    await writeText(handle, encodePage(page));
  }

  async loadPage(id) {
    const handle = await this.pageHandle(id);
    let raw;
    try {
      raw = JSON.parse(await readText(handle));
    } catch {
      throw new Error("That page file is damaged.");
    }
    const page = decodePage(raw);
    page.id = id;
    return page;
  }

  async loadAsset(name) {
    if (!name || name.includes("/") || name.includes("\\") || name.startsWith(".")) return null;
    try {
      const assets = await dirIn(this.root, "assets");
      const handle = await fileIn(assets, name);
      const file = await handle.getFile();
      return await file.arrayBuffer();
    } catch {
      return null;
    }
  }

  /// Adopt `mutate`'s copy only after notebook.json is written. A false result writes nothing.
  async commit(mutate) {
    const next = structuredClone(this.notebook);
    const result = mutate(next);
    if (result === false) return false;
    const previous = this.notebook;
    this.notebook = next;
    try {
      await this.writeManifest();
      return result;
    } catch (error) {
      this.notebook = previous;
      throw error;
    }
  }

  saveManifest() {
    return this.enqueue(() => this.writeManifest());
  }

  savePage(page) {
    return this.enqueue(async () => {
      await this.writePage(page);
      const index = sectionOf(this.notebook, page.id);
      if (index < 0) return;
      const listed = flattenPages(this.notebook.sections[index].items).find((item) => item.id.toUpperCase() === page.id.toUpperCase());
      if (listed && listed.title !== page.title) {
        await this.commit((notebook) => { setTitle(notebook.sections[index], page.id, page.title); return true; });
      }
    });
  }

  addPage(title, sectionIndex, folderId) {
    return this.enqueue(async () => {
      const section = this.notebook.sections[sectionIndex];
      if (!section || section.locked) throw new Error("That section cannot take a new page.");
      const page = emptyPage(title);
      await this.writePage(page);
      await this.commit((notebook) => { addPage(notebook.sections[sectionIndex], page, folderId); return true; });
      return page;
    });
  }

  /// The manifest drops the page. The page file stays, because the browser cannot move it to the Trash.
  deletePage(id) {
    return this.enqueue(() => this.commit((notebook) => removePage(notebook, id) ? true : false));
  }

  addFolder(name, sectionIndex, parentId) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = notebook.sections[sectionIndex];
      if (!section || section.locked) throw new Error("That section cannot take a new folder.");
      return addFolder(section, name, parentId);
    }));
  }

  renameFolder(id, sectionIndex, name) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = notebook.sections[sectionIndex];
      if (!section || !renameFolder(section, id, name)) return false;
      return true;
    }));
  }

  setColor(id, sectionIndex, colorHex) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = notebook.sections[sectionIndex];
      if (!section || !setItemColor(section, id, colorHex)) return false;
      return true;
    }));
  }

  dissolveFolder(id, sectionIndex) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = notebook.sections[sectionIndex];
      if (!section || !dissolveFolder(section, id)) return false;
      return true;
    }));
  }

  moveItem(id, sectionIndex, parent, index) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = notebook.sections[sectionIndex];
      if (!section || !moveItem(section, id, parent, index)) return false;
      return true;
    }));
  }

  relocate(id, fromIndex, toIndex) {
    return this.enqueue(() => this.commit((notebook) => {
      const from = notebook.sections[fromIndex];
      const to = notebook.sections[toIndex];
      if (!from || !to || to.locked || fromIndex === toIndex) return false;
      const node = takeItem(from.items, id);
      if (!node) return false;
      to.items.push(node);
      return true;
    }));
  }

  addSection(name) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = { id: uuid(), name, locked: false, items: [] };
      notebook.sections.push(section);
      return section;
    }));
  }

  renameSection(id, name) {
    return this.enqueue(() => this.commit((notebook) => {
      const section = notebook.sections.find((item) => item.id.toUpperCase() === id.toUpperCase());
      if (!section) return false;
      section.name = name;
      return true;
    }));
  }

  deleteSection(id) {
    return this.enqueue(() => this.commit((notebook) => {
      if (notebook.sections.length < 2) throw new Error("A notebook needs at least one section.");
      const index = notebook.sections.findIndex((item) => item.id.toUpperCase() === id.toUpperCase());
      if (index < 0) return false;
      notebook.sections.splice(index, 1);
      return true;
    }));
  }

  moveSection(id, index) {
    return this.enqueue(() => this.commit((notebook) => moveSection(notebook, id, index) ? true : false));
  }

  renameNotebook(name) {
    return this.enqueue(() => this.commit((notebook) => { notebook.name = name; return true; }));
  }

  addAsset(data, ext) {
    return this.enqueue(async () => {
      const name = assetName(ext);
      const assets = await dirIn(this.root, "assets", { create: true });
      const handle = await fileIn(assets, name, { create: true });
      await writeBytes(handle, data);
      return name;
    });
  }
}

function takeItem(items, id) {
  const index = items.findIndex((item) => item.id.toUpperCase() === String(id).toUpperCase());
  if (index >= 0) return items.splice(index, 1)[0];
  for (const item of items) {
    if (item.kind === "folder") {
      const taken = takeItem(item.children, id);
      if (taken) return taken;
    }
  }
  return null;
}

export { findItem };
