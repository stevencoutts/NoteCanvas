// Notebook and page model shared with the Mac app.
// Swift's synthesized Codable wraps each enum payload in "_0".
// notebook.json and page files use pretty-printed, sorted keys, with "/" escaped.

export const NOTEBOOK_VERSION = 1;
export const MIN_TEXT_WIDTH = 40;
export const MIN_TEXT_HEIGHT = 20;
export const MIN_IMAGE = 32;
export const MAX_IMAGE_SIDE = 480;
export const BASE_FONT = 14;
export const HEADING_SCALES = [1, 1.8, 1.4, 1.2];
export const MAX_INDENT = 8;
export const HANDLE = 14;
export const INSET = 6;
export const GRIP = 8;
export const LIST_GAP = 18;
export const INDENT_STEP = 24;

export const SWATCHES = [
  { name: "Red", hex: "#A33B32" },
  { name: "Orange", hex: "#C4622D" },
  { name: "Gold", hex: "#8F7020" },
  { name: "Green", hex: "#3D7048" },
  { name: "Teal", hex: "#2A6E68" },
  { name: "Blue", hex: "#34547E" },
  { name: "Purple", hex: "#684674" },
  { name: "Default", hex: null },
];

export const INK = "#3D362E";

export function uuid() {
  return globalThis.crypto.randomUUID().toUpperCase();
}

export function assetName(ext) {
  const clean = String(ext || "").toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 8);
  return `${uuid()}.${clean || "bin"}`;
}

export function sameId(a, b) {
  return String(a).toUpperCase() === String(b).toUpperCase();
}

export function safeHex(hex) {
  return /^#[0-9A-Fa-f]{6}$/.test(hex || "") ? hex.toUpperCase() : null;
}

export class History {
  constructor(limit = 200) {
    this.undoStack = [];
    this.redoStack = [];
    this.limit = limit;
  }
  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }
  record(before) {
    this.undoStack.push(structuredClone(before));
    if (this.undoStack.length > this.limit) this.undoStack.splice(0, this.undoStack.length - this.limit);
    this.redoStack = [];
  }
  discardLast() { this.undoStack.pop(); }
  undo(current) {
    const previous = this.undoStack.pop();
    if (!previous) return null;
    this.redoStack.push(structuredClone(current));
    return previous;
  }
  redo(current) {
    const next = this.redoStack.pop();
    if (!next) return null;
    this.undoStack.push(structuredClone(current));
    return next;
  }
}

export function emptyNotebook(name) {
  return {
    version: NOTEBOOK_VERSION,
    name,
    revision: 0,
    sections: [{ id: uuid(), name: "Section 1", locked: false, items: [] }],
  };
}

export function emptyPage(title) {
  return { id: uuid(), title, objects: [] };
}

function num(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function clamp(n, lo, hi) {
  return Math.min(Math.max(n, lo), hi);
}

export function clampParagraph(p) {
  p.indent = clamp(p.indent | 0, 0, MAX_INDENT);
  p.heading = clamp(p.heading | 0, 0, 3);
  if (p.list !== "bullet" && p.list !== "numbered") p.list = "none";
  if (p.alignment !== "center" && p.alignment !== "right") p.alignment = "left";
}

function styleFrom(raw) {
  const s = raw && typeof raw === "object" ? raw : {};
  const style = {
    bold: !!s.bold,
    italic: !!s.italic,
    underline: !!s.underline,
    strike: !!s.strike,
    script: s.script === "sup" || s.script === "sub" ? s.script : "normal",
  };
  if (typeof s.fontName === "string" && s.fontName) style.fontName = s.fontName;
  if (s.fontSize != null && Number.isFinite(Number(s.fontSize))) style.fontSize = Number(s.fontSize);
  const color = safeHex(s.colorHex);
  if (color) style.colorHex = color;
  const highlight = safeHex(s.highlightHex);
  if (highlight) style.highlightHex = highlight;
  if (typeof s.link === "string" && s.link) style.link = s.link;
  return style;
}

function decodeParagraph(raw) {
  const p = {
    runs: Array.isArray(raw?.runs) ? raw.runs.map((r) => ({
      text: String(r?.text ?? ""),
      style: styleFrom(r?.style),
    })) : [],
    indent: num(raw?.indent),
    heading: num(raw?.heading),
    list: raw?.list || "none",
    alignment: raw?.alignment || "left",
  };
  clampParagraph(p);
  return p;
}

function unwrap(payload) {
  if (payload && typeof payload === "object" && Object.prototype.hasOwnProperty.call(payload, "_0") && !Object.prototype.hasOwnProperty.call(payload, "id")) {
    return payload._0;
  }
  return payload;
}

function decodeFrame(raw) {
  return {
    x: num(raw?.x),
    y: num(raw?.y),
    width: num(raw?.width),
    height: num(raw?.height),
  };
}

export function decodeObject(raw) {
  const type = ["text", "image", "table", "attachment"].find((key) => raw && raw[key] != null);
  if (!type) return null;
  const body = unwrap(raw[type]) || {};
  const frame = decodeFrame(body.frame);
  if (type === "text") {
    return {
      type,
      id: String(body.id),
      frame,
      paragraphs: Array.isArray(body.paragraphs) ? body.paragraphs.map(decodeParagraph) : [],
    };
  }
  if (type === "image") {
    return { type, id: String(body.id), frame, asset: String(body.asset || ""), altText: body.altText || null };
  }
  if (type === "attachment") {
    return { type, id: String(body.id), frame, asset: String(body.asset || ""), displayName: String(body.displayName || "Attachment") };
  }
  return {
    type,
    id: String(body.id),
    frame,
    columnWidths: Array.isArray(body.columnWidths) ? body.columnWidths.map((n) => num(n)) : [],
    rows: Array.isArray(body.rows) ? body.rows.map((row) => (Array.isArray(row) ? row.map((cell) => ({
      paragraphs: Array.isArray(cell?.paragraphs) ? cell.paragraphs.map(decodeParagraph) : [],
    })) : [])) : [],
    bordersVisible: body.bordersVisible !== false,
  };
}

export function decodePage(raw) {
  if (!raw || typeof raw !== "object") throw new Error("This page file is damaged.");
  return {
    id: String(raw.id),
    title: String(raw.title ?? ""),
    objects: (Array.isArray(raw.objects) ? raw.objects : []).map(decodeObject).filter(Boolean),
  };
}

function decodeItem(raw) {
  if (raw?.page) {
    const page = unwrap(raw.page) || {};
    return { kind: "page", id: String(page.id), title: String(page.title ?? ""), colorHex: safeHex(page.colorHex) };
  }
  if (raw?.folder) {
    const folder = unwrap(raw.folder) || {};
    return {
      kind: "folder",
      id: String(folder.id),
      name: String(folder.name ?? "Folder"),
      colorHex: safeHex(folder.colorHex),
      children: Array.isArray(folder.children) ? folder.children.map(decodeItem) : [],
    };
  }
  return null;
}

function pageRef(raw) {
  return { kind: "page", id: String(raw.id), title: String(raw.title ?? ""), colorHex: safeHex(raw.colorHex) };
}

export function decodeSection(raw) {
  const section = {
    id: String(raw.id),
    name: String(raw.name ?? "Section"),
    locked: raw.locked === true,
    items: [],
  };
  if (section.locked) return section;
  if (Array.isArray(raw.items)) section.items = raw.items.map(decodeItem).filter(Boolean);
  else if (Array.isArray(raw.pages)) section.items = raw.pages.map(pageRef);
  return section;
}

export function decodeNotebook(raw) {
  if (!raw || typeof raw !== "object") throw new Error("This notebook file is damaged.");
  const version = num(raw.version, NaN);
  if (version !== NOTEBOOK_VERSION) throw new Error(`This notebook uses version ${raw.version}, which this app cannot read.`);
  return {
    version,
    name: String(raw.name ?? "Notebook"),
    revision: num(raw.revision),
    sections: Array.isArray(raw.sections) ? raw.sections.map(decodeSection) : [],
  };
}

function styleJSON(style) {
  const out = {
    bold: !!style?.bold,
    italic: !!style?.italic,
    script: style?.script === "sup" || style?.script === "sub" ? style.script : "normal",
    strike: !!style?.strike,
    underline: !!style?.underline,
  };
  if (style?.fontName) out.fontName = style.fontName;
  if (style?.fontSize != null) out.fontSize = style.fontSize;
  if (style?.colorHex) out.colorHex = style.colorHex;
  if (style?.highlightHex) out.highlightHex = style.highlightHex;
  if (style?.link) out.link = style.link;
  return out;
}

function paragraphJSON(p) {
  return {
    alignment: p.alignment || "left",
    heading: p.heading | 0,
    indent: p.indent | 0,
    list: p.list || "none",
    runs: (p.runs || []).map((r) => ({ style: styleJSON(r.style), text: r.text ?? "" })),
  };
}

function frameJSON(frame) {
  return { height: frame.height, width: frame.width, x: frame.x, y: frame.y };
}

function objectJSON(object) {
  if (object.type === "text") {
    return { text: { _0: { frame: frameJSON(object.frame), id: object.id, paragraphs: object.paragraphs.map(paragraphJSON) } } };
  }
  if (object.type === "image") {
    const body = { asset: object.asset, frame: frameJSON(object.frame), id: object.id };
    if (object.altText) body.altText = object.altText;
    return { image: { _0: body } };
  }
  if (object.type === "attachment") {
    return { attachment: { _0: { asset: object.asset, displayName: object.displayName, frame: frameJSON(object.frame), id: object.id } } };
  }
  return {
    table: {
      _0: {
        bordersVisible: !!object.bordersVisible,
        columnWidths: object.columnWidths || [],
        frame: frameJSON(object.frame),
        id: object.id,
        rows: (object.rows || []).map((row) => row.map((cell) => ({ paragraphs: (cell.paragraphs || []).map(paragraphJSON) }))),
      },
    },
  };
}

export function encodePage(page) {
  return swiftStringify({
    id: page.id,
    objects: page.objects.map(objectJSON),
    title: page.title,
  });
}

function refJSON(page) {
  const out = { id: page.id, title: page.title };
  if (page.colorHex) out.colorHex = page.colorHex;
  return out;
}

function itemJSON(item) {
  if (item.kind === "page") return { page: { _0: refJSON(item) } };
  const folder = { children: item.children.map(itemJSON), id: item.id, name: item.name };
  if (item.colorHex) folder.colorHex = item.colorHex;
  return { folder: { _0: folder } };
}

export function flattenPages(items) {
  const pages = [];
  for (const item of items) {
    if (item.kind === "page") pages.push(item);
    else pages.push(...flattenPages(item.children || []));
  }
  return pages;
}

function sectionJSON(section) {
  if (section.locked) return { id: section.id, locked: true, name: section.name };
  return {
    id: section.id,
    items: section.items.map(itemJSON),
    name: section.name,
    pages: flattenPages(section.items).map(refJSON),
  };
}

export function encodeNotebook(notebook) {
  const out = {
    name: notebook.name,
    sections: notebook.sections.map(sectionJSON),
    version: notebook.version || NOTEBOOK_VERSION,
  };
  if (notebook.revision) out.revision = notebook.revision;
  return swiftStringify(out);
}

function quote(value) {
  let out = '"';
  for (const ch of value) {
    const code = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "/") out += "\\/";
    else if (ch === "\b") out += "\\b";
    else if (ch === "\f") out += "\\f";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\t") out += "\\t";
    else if (code < 0x20) out += `\\u${code.toString(16).padStart(4, "0")}`;
    else out += ch;
  }
  return `${out}"`;
}

function numberText(value) {
  if (!Number.isFinite(value)) throw new Error("Cannot store a non-finite number.");
  if (Object.is(value, -0)) return "0";
  if (Number.isInteger(value)) return String(value);
  const text = String(value);
  if (!/[eE]/.test(text)) return text;
  return value.toFixed(12).replace(/0+$/, "").replace(/\.$/, "");
}

function stringify(value, indent) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return numberText(value);
  if (typeof value === "string") return quote(value);
  const pad = " ".repeat(indent);
  if (Array.isArray(value)) {
    if (value.length === 0) return `[\n\n${pad}]`;
    const inner = indent + 2;
    const lines = value.map((item) => `${" ".repeat(inner)}${stringify(item, inner)}`);
    return `[\n${lines.join(",\n")}\n${pad}]`;
  }
  const keys = Object.keys(value).filter((key) => value[key] !== undefined).sort();
  if (keys.length === 0) return `{\n\n${pad}}`;
  const inner = indent + 2;
  const lines = keys.map((key) => `${" ".repeat(inner)}${quote(key)} : ${stringify(value[key], inner)}`);
  return `{\n${lines.join(",\n")}\n${pad}}`;
}

export function swiftStringify(value) {
  return stringify(value, 0);
}

export function plainText(paragraphs) {
  return (paragraphs || []).map((p) => (p.runs || []).map((r) => r.text).join("")).join("\n");
}

export function isEmptyText(object) {
  return object?.type === "text" && (object.paragraphs || []).every((p) => (p.runs || []).every((r) => !r.text));
}

export function findItem(items, id) {
  for (const item of items) {
    if (sameId(item.id, id)) return item;
    if (item.kind === "folder") {
      const found = findItem(item.children, id);
      if (found) return found;
    }
  }
  return null;
}

export function findFolder(items, id) {
  const item = findItem(items, id);
  return item?.kind === "folder" ? item : null;
}

export function parentOf(items, id, parent = null) {
  for (const item of items) {
    if (sameId(item.id, id)) return { found: true, parent };
    if (item.kind === "folder") {
      const nested = parentOf(item.children, id, item.id);
      if (nested.found) return nested;
    }
  }
  return { found: false, parent: null };
}

function locate(items, id, parent = null) {
  for (let index = 0; index < items.length; index += 1) {
    const item = items[index];
    if (sameId(item.id, id)) return { parent, index };
    if (item.kind === "folder") {
      const found = locate(item.children, id, item.id);
      if (found) return found;
    }
  }
  return null;
}

function contains(items, id, folderId) {
  const folder = findFolder(items, folderId);
  if (!folder) return false;
  return locate(folder.children, id, folderId) != null;
}

function removeItem(items, id) {
  const index = items.findIndex((item) => sameId(item.id, id));
  if (index >= 0) return items.splice(index, 1)[0];
  for (const item of items) {
    if (item.kind === "folder") {
      const removed = removeItem(item.children, id);
      if (removed) return removed;
    }
  }
  return null;
}

function insertItem(items, folderId, item, index) {
  for (let i = 0; i < items.length; i += 1) {
    const current = items[i];
    if (current.kind !== "folder") continue;
    if (sameId(current.id, folderId)) {
      const at = clamp(index ?? current.children.length, 0, current.children.length);
      current.children.splice(at, 0, item);
      return true;
    }
    if (insertItem(current.children, folderId, item, index)) return true;
  }
  return false;
}

export function addPage(section, ref, folderId = null) {
  const item = { kind: "page", id: ref.id, title: ref.title, colorHex: ref.colorHex || null };
  if (folderId && insertItem(section.items, folderId, item, null)) return;
  section.items.push(item);
}

export function addFolder(section, name, parentId = null) {
  const folder = { kind: "folder", id: uuid(), name, colorHex: null, children: [] };
  if (parentId && insertItem(section.items, parentId, folder, null)) return folder.id;
  section.items.push(folder);
  return folder.id;
}

export function renameFolder(section, id, name) {
  const folder = findFolder(section.items, id);
  if (!folder) return false;
  folder.name = name;
  return true;
}

export function setTitle(section, id, title) {
  const item = findItem(section.items, id);
  if (!item || item.kind !== "page") return false;
  item.title = title;
  return true;
}

export function setItemColor(section, id, colorHex) {
  const item = findItem(section.items, id);
  if (!item) return false;
  item.colorHex = safeHex(colorHex);
  return true;
}

export function dissolveFolder(section, id) {
  return dissolveIn(section.items, id);
}

function dissolveIn(items, id) {
  const index = items.findIndex((item) => sameId(item.id, id));
  if (index >= 0 && items[index].kind === "folder") {
    const folder = items[index];
    items.splice(index, 1, ...folder.children);
    return true;
  }
  for (const item of items) {
    if (item.kind === "folder" && dissolveIn(item.children, id)) return true;
  }
  return false;
}

export function removePage(notebook, id) {
  let removed = false;
  for (const section of notebook.sections) {
    if (removeItem(section.items, id)) removed = true;
  }
  return removed;
}

/// `index` is the gap in the destination as the list stands now (before the item is removed).
export function moveItem(section, id, parent, index) {
  if (parent) {
    if (sameId(parent, id) || contains(section.items, parent, id)) return false;
    if (!findFolder(section.items, parent)) return false;
  }
  const location = locate(section.items, id, null);
  if (!location) return false;
  let adjusted = index;
  if ((location.parent ?? null) === (parent ?? null) && location.index < index) adjusted -= 1;
  const node = removeItem(section.items, id);
  if (!node) return false;
  const limit = parent == null ? section.items.length : (findFolder(section.items, parent)?.children.length ?? 0);
  const at = clamp(adjusted, 0, limit);
  if (parent) {
    if (!insertItem(section.items, parent, node, at)) {
      section.items.push(node);
      return false;
    }
  } else {
    section.items.splice(at, 0, node);
  }
  return true;
}

export function moveSection(notebook, id, index) {
  const from = notebook.sections.findIndex((section) => sameId(section.id, id));
  if (from < 0) return false;
  let target = index;
  if (from < target) target -= 1;
  const [section] = notebook.sections.splice(from, 1);
  notebook.sections.splice(clamp(target, 0, notebook.sections.length), 0, section);
  return true;
}

export function sectionOf(notebook, id) {
  return notebook.sections.findIndex((section) => sameId(section.id, id) || findItem(section.items, id));
}

export function overlaps(a, b, gap) {
  return a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap && b.y < a.y + a.height + gap;
}

export function clearOrigin(width, height, nearX, nearY, frames, gap = 16) {
  let y = nearY;
  for (let n = 0; n <= frames.length; n += 1) {
    const candidate = { x: nearX, y, width, height };
    const blockers = frames.filter((frame) => overlaps(frame, candidate, gap));
    if (!blockers.length) return { x: nearX, y };
    let lowest = blockers[0];
    for (const frame of blockers) {
      if (frame.y + frame.height > lowest.y + lowest.height) lowest = frame;
    }
    y = lowest.y + lowest.height + gap;
  }
  return { x: nearX, y };
}

export function scaledImageFrame(start, corner, dx, dy, minimum = MIN_IMAGE) {
  const growX = corner === "bottomLeft" || corner === "topLeft" ? -dx : dx;
  const growY = corner === "topLeft" || corner === "topRight" ? -dy : dy;
  const scaleX = (start.width + growX) / Math.max(start.width, 1);
  const scaleY = (start.height + growY) / Math.max(start.height, 1);
  let scale = Math.abs(growX) >= Math.abs(growY) ? scaleX : scaleY;
  const minScale = Math.max(minimum / Math.max(start.width, 1), minimum / Math.max(start.height, 1));
  if (scale < minScale) scale = minScale;
  const width = start.width * scale;
  const height = start.height * scale;
  if (corner === "bottomRight") return { x: start.x, y: start.y, width, height };
  if (corner === "bottomLeft") return { x: start.x + start.width - width, y: start.y, width, height };
  if (corner === "topRight") return { x: start.x, y: start.y + start.height - height, width, height };
  return { x: start.x + start.width - width, y: start.y + start.height - height, width, height };
}

export function fittedSize(width, height) {
  if (!(width > 1) || !(height > 1)) return { width: 240, height: 180 };
  const scale = Math.min(1, MAX_IMAGE_SIDE / Math.max(width, height));
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

export function duplicateObject(object, dx, dy) {
  const copy = structuredClone(object);
  copy.id = uuid();
  copy.frame.x += dx;
  copy.frame.y += dy;
  return copy;
}

export function textIsBlank(paragraphs) {
  return plainText(paragraphs).trim() === "";
}

const URL_RE = /\b(?:https?:\/\/|www\.)[^\s<]+[^\s<.,;:!?)]|\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g;

export function linkifyParagraphs(paragraphs) {
  return paragraphs.map((paragraph) => {
    const runs = [];
    for (const run of paragraph.runs) {
      if (run.style?.link || !run.text) {
        runs.push(run);
        continue;
      }
      URL_RE.lastIndex = 0;
      let cursor = 0;
      let match = URL_RE.exec(run.text);
      if (!match) {
        runs.push(run);
        continue;
      }
      while (match) {
        if (match.index > cursor) runs.push({ text: run.text.slice(cursor, match.index), style: { ...run.style } });
        let link = match[0];
        if (link.toLowerCase().startsWith("www.")) link = `https://${link}`;
        else if (!/^https?:/i.test(link)) link = `mailto:${link}`;
        runs.push({ text: match[0], style: { ...run.style, link } });
        cursor = match.index + match[0].length;
        match = URL_RE.exec(run.text);
      }
      if (cursor < run.text.length) runs.push({ text: run.text.slice(cursor), style: { ...run.style } });
    }
    return { ...paragraph, runs };
  });
}

export function runLength(paragraph) {
  return (paragraph.runs || []).reduce((sum, run) => sum + run.text.length, 0);
}

export function stylesEqual(a, b) {
  const keys = ["bold", "italic", "underline", "strike", "fontName", "fontSize", "colorHex", "highlightHex", "script", "link"];
  return keys.every((key) => (a?.[key] ?? (key === "script" ? "normal" : key === "bold" || key === "italic" || key === "underline" || key === "strike" ? false : undefined))
    === (b?.[key] ?? (key === "script" ? "normal" : key === "bold" || key === "italic" || key === "underline" || key === "strike" ? false : undefined)));
}

/// Applies `mutate` to the style of every character in the selection. A collapsed selection returns false.
export function mapRuns(paragraphs, sel, mutate) {
  const start = sel.start.paragraph < sel.end.paragraph || (sel.start.paragraph === sel.end.paragraph && sel.start.offset <= sel.end.offset)
    ? sel.start : sel.end;
  const end = start === sel.start ? sel.end : sel.start;
  if (start.paragraph === end.paragraph && start.offset === end.offset) return false;
  for (let p = start.paragraph; p <= end.paragraph && p < paragraphs.length; p += 1) {
    const from = p === start.paragraph ? start.offset : 0;
    const to = p === end.paragraph ? end.offset : runLength(paragraphs[p]);
    paragraphs[p].runs = mapParagraphRuns(paragraphs[p].runs, from, to, mutate);
  }
  return true;
}

function mapParagraphRuns(runs, from, to, mutate) {
  if (to <= from) return runs;
  const next = [];
  let cursor = 0;
  for (const run of runs) {
    const end = cursor + run.text.length;
    if (end <= from || cursor >= to) next.push(run);
    else {
      if (cursor < from) next.push({ text: run.text.slice(0, from - cursor), style: { ...run.style } });
      const sliceFrom = Math.max(0, from - cursor);
      const sliceTo = Math.min(run.text.length, to - cursor);
      const style = { ...run.style };
      mutate(style);
      next.push({ text: run.text.slice(sliceFrom, sliceTo), style });
      if (end > to) next.push({ text: run.text.slice(to - cursor), style: { ...run.style } });
    }
    cursor = end;
  }
  return next.filter((run) => run.text.length > 0);
}

export function rangeIsOn(paragraphs, sel, key) {
  const start = sel.start.paragraph < sel.end.paragraph || (sel.start.paragraph === sel.end.paragraph && sel.start.offset <= sel.end.offset)
    ? sel.start : sel.end;
  const end = start === sel.start ? sel.end : sel.start;
  for (let p = start.paragraph; p <= end.paragraph && p < paragraphs.length; p += 1) {
    const from = p === start.paragraph ? start.offset : 0;
    const to = p === end.paragraph ? end.offset : runLength(paragraphs[p]);
    let cursor = 0;
    for (const run of paragraphs[p].runs) {
      const runEnd = cursor + run.text.length;
      if (runEnd > from && cursor < to && !run.style?.[key]) return false;
      cursor = runEnd;
    }
  }
  return true;
}

export function splitParagraph(paragraphs, paragraphIndex, offset) {
  const paragraph = paragraphs[paragraphIndex];
  if (!paragraph) return;
  const left = [];
  const right = [];
  let cursor = 0;
  for (const run of paragraph.runs) {
    const end = cursor + run.text.length;
    if (end <= offset) left.push(run);
    else if (cursor >= offset) right.push(run);
    else {
      left.push({ text: run.text.slice(0, offset - cursor), style: { ...run.style } });
      right.push({ text: run.text.slice(offset - cursor), style: { ...run.style } });
    }
    cursor = end;
  }
  paragraph.runs = left;
  paragraphs.splice(paragraphIndex + 1, 0, {
    runs: right,
    indent: paragraph.indent,
    heading: paragraph.heading,
    list: paragraph.list,
    alignment: paragraph.alignment,
  });
}

export function mergeParagraph(paragraphs, paragraphIndex) {
  if (paragraphIndex <= 0) return;
  const previous = paragraphs[paragraphIndex - 1];
  const current = paragraphs[paragraphIndex];
  previous.runs = previous.runs.concat(current.runs);
  paragraphs.splice(paragraphIndex, 1);
}

export function paragraphRange(sel) {
  const start = Math.min(sel.start.paragraph, sel.end.paragraph);
  let end = Math.max(sel.start.paragraph, sel.end.paragraph);
  const forwardEnd = sel.start.paragraph < sel.end.paragraph || (sel.start.paragraph === sel.end.paragraph && sel.start.offset <= sel.end.offset)
    ? sel.end : sel.start;
  const forwardStart = forwardEnd === sel.end ? sel.start : sel.end;
  if (forwardStart.paragraph !== forwardEnd.paragraph && forwardEnd.offset === 0) end -= 1;
  if (end < start) end = start;
  return [start, end];
}
