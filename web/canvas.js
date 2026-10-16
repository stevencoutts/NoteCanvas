// Free-form page: text boxes, images, and read-only tables and attachments.
// One undo step covers a typing session, a drag, or a format change, as on the Mac.

import {
  BASE_FONT, HANDLE, HEADING_SCALES, History, INSET, MIN_TEXT_HEIGHT, MIN_TEXT_WIDTH,
  clearOrigin, clampParagraph, duplicateObject, fittedSize, isEmptyText, linkifyParagraphs,
  mapRuns, mergeParagraph, paragraphRange, rangeIsOn, runLength, safeHex, scaledImageFrame,
  splitParagraph, stylesEqual, uuid,
} from "./model.js";

const CORNERS = ["topLeft", "topRight", "bottomLeft", "bottomRight"];

function el(tag, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}

function rgbToHex(value) {
  const match = String(value || "").match(/rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/);
  if (!match) return null;
  if (match[4] != null && Number(match[4]) === 0) return null;
  return `#${[match[1], match[2], match[3]].map((part) => Number(part).toString(16).padStart(2, "0")).join("")}`.toUpperCase();
}

function safeURL(link) {
  try {
    const url = new URL(link);
    if (url.protocol === "http:" || url.protocol === "https:" || url.protocol === "mailto:") return url.href;
  } catch { /* leave it */ }
  return null;
}

function paint(span, style, heading) {
  const scale = HEADING_SCALES[Math.min(Math.max(heading | 0, 0), 3)];
  span.style.fontSize = `${(style?.fontSize || BASE_FONT) * scale}px`;
  span.style.fontWeight = style?.bold ? "700" : "400";
  span.style.fontStyle = style?.italic ? "italic" : "normal";
  const deco = [];
  if (style?.underline || style?.link) deco.push("underline");
  if (style?.strike) deco.push("line-through");
  span.style.textDecoration = deco.join(" ") || "none";
  span.style.color = style?.colorHex || (style?.link ? "#34547E" : "#000000");
  span.style.backgroundColor = style?.highlightHex || "transparent";
  if (style?.fontName) {
    span.dataset.font = style.fontName;
    span.style.fontFamily = style.fontName;
  }
  if (style?.script === "sup" || style?.script === "sub") {
    span.dataset.script = style.script;
    span.style.verticalAlign = style.script === "sup" ? "super" : "sub";
  }
  if (style?.link) span.dataset.link = style.link;
  span.classList.toggle("link", !!style?.link);
}

function styleOf(node, heading) {
  const view = getComputedStyle(node);
  const scale = HEADING_SCALES[Math.min(Math.max(heading | 0, 0), 3)] || 1;
  const pt = Math.round(((parseFloat(view.fontSize) || BASE_FONT) / scale) * 2) / 2;
  const style = {
    bold: (parseInt(view.fontWeight, 10) || 400) >= 600,
    italic: view.fontStyle === "italic",
    underline: (view.textDecorationLine || "").includes("underline"),
    strike: (view.textDecorationLine || "").includes("line-through"),
    script: "normal",
  };
  const script = node.closest("[data-script]")?.dataset.script;
  if (script === "sup" || script === "sub") style.script = script;
  if (Math.abs(pt - BASE_FONT) > 0.01) style.fontSize = pt;
  const color = rgbToHex(view.color);
  if (color && color !== "#000000") style.colorHex = color;
  const highlight = rgbToHex(view.backgroundColor);
  if (highlight) style.highlightHex = highlight;
  const font = node.closest("[data-font]")?.dataset.font;
  if (font) style.fontName = font;
  const link = node.closest("[data-link]")?.dataset.link;
  if (link) style.link = link;
  return style;
}

function markersFor(paragraphs) {
  const markers = [];
  let counters = {};
  for (const paragraph of paragraphs) {
    const next = { ...counters };
    for (const key of Object.keys(next)) if (Number(key) > paragraph.indent) delete next[key];
    if (paragraph.list === "numbered") next[paragraph.indent] = (next[paragraph.indent] || 0) + 1;
    else delete next[paragraph.indent];
    counters = next;
    markers.push(paragraph.list === "numbered" ? counters[paragraph.indent] : null);
  }
  return markers;
}

function renderParagraphs(body, paragraphs) {
  body.replaceChildren();
  const source = paragraphs.length ? paragraphs : [{ runs: [], indent: 0, heading: 0, list: "none", alignment: "left" }];
  const numbers = markersFor(source);
  source.forEach((paragraph, index) => {
    const row = el("div", "para");
    row.dataset.heading = String(paragraph.heading || 0);
    row.dataset.list = paragraph.list || "none";
    row.dataset.indent = String(paragraph.indent || 0);
    row.dataset.align = paragraph.alignment || "left";
    const listed = paragraph.list && paragraph.list !== "none";
    const markerWidth = listed ? Math.max(18, paragraph.list === "numbered" ? String(numbers[index]).length * 10 + 8 : 18) : 0;
    row.style.paddingLeft = `${(paragraph.indent || 0) * 24 + markerWidth}px`;
    row.style.textIndent = listed ? `-${markerWidth}px` : "0";
    row.style.textAlign = paragraph.alignment || "left";
    if (listed) {
      const marker = el("span", "marker");
      marker.contentEditable = "false";
      marker.style.width = `${markerWidth}px`;
      marker.textContent = paragraph.list === "bullet" ? "•" : `${numbers[index]}.`;
      row.append(marker);
    }
    const runs = (paragraph.runs || []).filter((run) => run.text);
    if (!runs.length) row.append(document.createElement("br"));
    for (const run of runs) {
      const span = el("span", "run");
      paint(span, run.style, paragraph.heading || 0);
      span.textContent = run.text;
      row.append(span);
    }
    body.append(row);
  });
  body.dataset.sig = JSON.stringify(paragraphs);
}

function visibleText(node) {
  return (node.textContent || "").replace(/\u200b/g, "");
}

function collectRuns(node, heading, runs) {
  for (const child of node.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      const text = visibleText(child);
      if (!text) continue;
      const style = styleOf(child.parentElement || node, heading);
      const last = runs.at(-1);
      if (last && stylesEqual(last.style, style)) last.text += text;
      else runs.push({ text, style });
    } else if (child.nodeType === Node.ELEMENT_NODE) {
      if (child.classList.contains("marker") || child.tagName === "BR") continue;
      collectRuns(child, heading, runs);
    }
  }
}

function parsePara(row) {
  const paragraph = {
    runs: [],
    indent: Number(row.dataset.indent || 0),
    heading: Number(row.dataset.heading || 0),
    list: row.dataset.list || "none",
    alignment: row.dataset.align || "left",
  };
  collectRuns(row, paragraph.heading, paragraph.runs);
  clampParagraph(paragraph);
  return paragraph;
}

function parseBody(body) {
  const rows = [...body.children].filter((node) => node.classList?.contains("para"));
  if (rows.length) return rows.map(parsePara);
  const text = body.innerText.replace(/\u200b/g, "").replace(/\r/g, "");
  if (!text) return [];
  return text.split("\n").map((line) => ({
    runs: line ? [{ text: line, style: styleOf(body, 0) }] : [],
    indent: 0, heading: 0, list: "none", alignment: "left",
  }));
}

function isClean(body) {
  for (const child of body.childNodes) {
    if (child.nodeType !== Node.ELEMENT_NODE || !child.classList.contains("para")) return false;
    for (const inner of child.childNodes) {
      if (inner.nodeType === Node.TEXT_NODE && visibleText(inner)) return false;
      if (inner.nodeType === Node.ELEMENT_NODE && !inner.classList.contains("marker") && !inner.classList.contains("run") && inner.tagName !== "BR") return false;
    }
  }
  return true;
}

function pointIn(body, node, offset) {
  const host = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
  const row = host?.closest?.(".para");
  if (!row || !body.contains(row)) return null;
  const paragraph = [...body.children].indexOf(row);
  if (node === row) {
    let count = 0;
    for (let i = 0; i < offset && i < row.childNodes.length; i += 1) count += visibleText(row.childNodes[i]).length;
    return { paragraph, offset: count };
  }
  let count = 0;
  const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const text = walker.currentNode;
    if (text.parentElement?.closest(".marker")) continue;
    if (text === node) return { paragraph, offset: count + Math.min(offset, visibleText(text).length) };
    count += visibleText(text).length;
  }
  return { paragraph, offset: count };
}

function captureSelection(body) {
  const selection = document.getSelection();
  if (!selection?.rangeCount || !body.contains(selection.anchorNode)) return null;
  const start = pointIn(body, selection.anchorNode, selection.anchorOffset);
  const end = pointIn(body, selection.focusNode, selection.focusOffset);
  if (!start || !end) return null;
  return { start, end };
}

function locate(row, offset) {
  const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
  let count = 0;
  let last = null;
  while (walker.nextNode()) {
    const text = walker.currentNode;
    if (text.parentElement?.closest(".marker")) continue;
    last = text;
    const raw = text.textContent || "";
    const visible = raw.replace(/\u200b/g, "");
    if (count + visible.length >= offset) {
      let left = offset - count;
      let index = 0;
      while (left > 0 && index < raw.length) {
        if (raw[index] !== "\u200b") left -= 1;
        index += 1;
      }
      return { node: text, offset: index };
    }
    count += visible.length;
  }
  if (last) return { node: last, offset: (last.textContent || "").length };
  return { node: row, offset: row.childNodes.length };
}

function restoreSelection(body, sel) {
  const startRow = body.children[sel.start.paragraph];
  const endRow = body.children[sel.end.paragraph];
  if (!startRow || !endRow) return;
  const start = locate(startRow, sel.start.offset);
  const end = locate(endRow, sel.end.offset);
  const range = document.createRange();
  range.setStart(start.node, start.offset);
  range.setEnd(end.node, end.offset);
  const selection = document.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}

function extensionOf(name, type) {
  const fromName = String(name || "").split(".").pop();
  if (fromName && fromName !== name) return fromName;
  return {
    "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
    "image/bmp": "bmp", "image/tiff": "tiff", "image/svg+xml": "svg",
  }[type] || "bin";
}

function measureImage(buffer) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(new Blob([buffer]));
    const image = new Image();
    image.onload = () => {
      const size = fittedSize(image.naturalWidth, image.naturalHeight);
      URL.revokeObjectURL(url);
      resolve(size);
    };
    image.onerror = () => {
      URL.revokeObjectURL(url);
      resolve(fittedSize(0, 0));
    };
    image.src = url;
  });
}

function fillReadonly(container, paragraphs) {
  container.replaceChildren();
  const numbers = markersFor(paragraphs || []);
  (paragraphs || []).forEach((paragraph, index) => {
    const line = el("div", "readonly-line");
    line.style.textAlign = paragraph.alignment || "left";
    line.style.paddingLeft = `${(paragraph.indent || 0) * 24}px`;
    if (paragraph.list === "bullet") line.append(document.createTextNode("• "));
    if (paragraph.list === "numbered") line.append(document.createTextNode(`${numbers[index]}. `));
    for (const run of paragraph.runs || []) {
      const span = el("span");
      paint(span, run.style, paragraph.heading || 0);
      span.textContent = run.text;
      line.append(span);
    }
    if (!line.textContent) line.append(document.createElement("br"));
    container.append(line);
  });
}

export class PageEditor {
  constructor(canvas, hooks) {
    this.canvas = canvas;
    this.hooks = hooks;
    this.page = null;
    this.history = new History();
    this.selected = null;
    this.typingContainer = null;
    this.justCreated = null;
    this.sparing = null;
    this.refreshing = false;
    this.composing = false;
    this.dragStart = null;
    this.dragRecorded = false;
    this.timer = null;
    this.dirty = false;
    this.assets = new Map();
    this.clipboard = null;
    this.clipboardFresh = false;
    this.pendingRestore = null;
    this.held = null;
    canvas.addEventListener("pointerdown", (event) => {
      if (event.target !== canvas) return;
      const rect = canvas.getBoundingClientRect();
      this.backgroundClick(event.clientX - rect.left, event.clientY - rect.top);
    });
    canvas.addEventListener("dragover", (event) => {
      if ([...event.dataTransfer.types].includes("Files")) event.preventDefault();
    });
    canvas.addEventListener("drop", (event) => {
      if (!event.dataTransfer.files?.length) return;
      event.preventDefault();
      this.insertFiles([...event.dataTransfer.files]);
    });
  }

  get editing() {
    return !!this.activeBody();
  }

  activeBody() {
    const node = document.activeElement;
    return node?.classList?.contains("body") && this.canvas.contains(node) ? node : null;
  }

  body(id) {
    return this.canvas.querySelector(`.obj[data-id="${CSS.escape(id)}"] .body`);
  }

  object(id) {
    return this.page?.objects.find((item) => item.id === id) || null;
  }

  rememberSelection() {
    const body = this.activeBody();
    this.held = body ? { id: body.dataset.id, sel: captureSelection(body) } : null;
  }

  recallSelection() {
    if (!this.held) return false;
    const held = this.held;
    this.held = null;
    const body = this.body(held.id);
    if (!body) return false;
    body.focus();
    if (held.sel) restoreSelection(body, held.sel);
    return true;
  }

  async load(page) {
    this.discardTimers();
    this.page = page;
    this.history = new History();
    this.selected = null;
    this.typingContainer = null;
    this.justCreated = null;
    this.dirty = false;
    this.revokeAssets();
    this.canvas.replaceChildren();
    this.sync();
  }

  discard() {
    this.discardTimers();
    this.dirty = false;
    this.page = null;
    this.selected = null;
    this.canvas.replaceChildren();
    this.revokeAssets();
  }

  discardTimers() {
    clearTimeout(this.timer);
    this.timer = null;
  }

  revokeAssets() {
    for (const url of this.assets.values()) URL.revokeObjectURL(url);
    this.assets.clear();
  }

  persist() {
    this.dirty = true;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { this.flush(); }, 500);
  }

  async flush() {
    clearTimeout(this.timer);
    this.timer = null;
    if (!this.page || !this.dirty) return true;
    const copy = structuredClone(this.page);
    this.dirty = false;
    const ok = await this.hooks.onPersist(copy);
    if (!ok) this.dirty = true;
    return !!ok;
  }

  setTitle(title) {
    if (!this.page || title === this.page.title) return;
    this.commit((page) => { page.title = title; });
    this.hooks.onTitle?.(title);
  }

  undo() {
    if (!this.page) return;
    this.pullActive();
    const previous = this.history.undo(this.page);
    if (previous) this.restore(previous);
  }

  redo() {
    if (!this.page) return;
    this.pullActive();
    const next = this.history.redo(this.page);
    if (next) this.restore(next);
  }

  restore(page) {
    this.page = page;
    this.typingContainer = null;
    this.justCreated = null;
    if (this.selected && !page.objects.some((item) => item.id === this.selected)) this.selected = null;
    this.sync({ force: true });
    this.persist();
    this.hooks.onSelection?.();
  }

  commit(change) {
    if (!this.page) return;
    this.history.record(this.page);
    this.typingContainer = null;
    this.justCreated = null;
    change(this.page);
    this.sync({ force: true });
    this.persist();
    this.hooks.onSelection?.();
  }

  backgroundClick(x, y) {
    if (!this.page) return;
    this.activeBody()?.blur();
    const id = uuid();
    this.history.record(this.page);
    this.typingContainer = null;
    this.page.objects.push({
      type: "text", id, frame: { x, y, width: 240, height: MIN_TEXT_HEIGHT }, paragraphs: [],
    });
    this.justCreated = id;
    this.selected = null;
    this.sync({ focus: id });
    this.persist();
    this.hooks.onSelection?.();
  }

  beginDrag(id) {
    this.sparing = id;
    this.activeBody()?.blur();
    this.sparing = null;
    this.selected = id;
    this.dragStart = structuredClone(this.page);
    this.dragRecorded = false;
    this.canvas.focus({ preventScroll: true });
    this.sync();
    this.hooks.onSelection?.();
  }

  drag(change) {
    if (!this.dragStart) return;
    if (!this.dragRecorded) {
      this.history.record(this.dragStart);
      this.typingContainer = null;
      this.justCreated = null;
      this.dragRecorded = true;
    }
    this.page = structuredClone(this.dragStart);
    change(this.page);
    this.sync();
  }

  endDrag() {
    const moved = this.dragRecorded;
    this.dragStart = null;
    this.dragRecorded = false;
    if (moved) this.persist();
  }

  deleteSelected() {
    if (!this.selected || this.editing) return;
    const id = this.selected;
    this.selected = null;
    this.commit((page) => { page.objects = page.objects.filter((item) => item.id !== id); });
  }

  bringToFront() {
    if (!this.selected) return;
    const id = this.selected;
    this.commit((page) => {
      const index = page.objects.findIndex((item) => item.id === id);
      if (index >= 0) page.objects.push(page.objects.splice(index, 1)[0]);
    });
  }

  sendToBack() {
    if (!this.selected) return;
    const id = this.selected;
    this.commit((page) => {
      const index = page.objects.findIndex((item) => item.id === id);
      if (index >= 0) page.objects.unshift(page.objects.splice(index, 1)[0]);
    });
  }

  copySelected() {
    const object = this.object(this.selected);
    if (!object) return null;
    this.clipboard = structuredClone(object);
    this.clipboardFresh = true;
    return JSON.stringify(object);
  }

  async pasteFrom(data) {
    if (!this.page) return;
    const custom = data?.getData?.("application/x-notecanvas-object") || "";
    if (custom) {
      try { this.pasteObject(JSON.parse(custom)); } catch { /* a copy from elsewhere */ }
      return;
    }
    const files = [...(data?.files || [])];
    if (!files.length && data?.items) {
      for (const item of data.items) {
        if (item.kind === "file") {
          const file = item.getAsFile();
          if (file) files.push(file);
        }
      }
    }
    if (files.length) { await this.insertFiles(files); return; }
    const text = data?.getData?.("text/plain")?.replace(/\r\n/g, "\n") || "";
    if (this.clipboardFresh && this.clipboard && !text.trim()) { this.pasteObject(this.clipboard); return; }
    if (!this.editing && text.trim()) this.pasteText(text);
  }

  pasteObject(object) {
    const copy = duplicateObject(object, 20, 20);
    if (copy.type === "image") {
      const origin = this.pasteOrigin();
      const spot = clearOrigin(copy.frame.width, copy.frame.height, origin.x, origin.y, this.page.objects.map((item) => item.frame));
      copy.frame.x = spot.x;
      copy.frame.y = spot.y;
    }
    this.selected = copy.id;
    this.commit((page) => page.objects.push(copy));
  }

  pasteText(text) {
    const origin = this.pasteOrigin();
    const paragraphs = text.split("\n").map((line) => ({
      runs: line ? [{ text: line, style: { bold: false, italic: false, underline: false, strike: false, script: "normal" } }] : [],
      indent: 0, heading: 0, list: "none", alignment: "left",
    }));
    const box = { type: "text", id: uuid(), frame: { x: origin.x, y: origin.y, width: 360, height: MIN_TEXT_HEIGHT }, paragraphs };
    this.selected = box.id;
    this.commit((page) => page.objects.push(box));
  }

  pasteOrigin() {
    const scroll = this.canvas.parentElement;
    if (!scroll) return { x: 48, y: 72 };
    return { x: scroll.scrollLeft + 32, y: scroll.scrollTop + 32 };
  }

  async insertFiles(fileList) {
    if (!this.page || !fileList?.length) return;
    const made = [];
    let stackY = null;
    for (const file of fileList) {
      const bytes = await file.arrayBuffer();
      if (!bytes.byteLength) continue;
      const image = (file.type || "").startsWith("image/") || /\.(png|jpe?g|gif|webp|bmp|tiff?|svg)$/i.test(file.name || "");
      const name = await this.hooks.storeAsset(bytes, extensionOf(file.name, file.type));
      if (!name) continue;
      if (image) {
        const size = await measureImage(bytes);
        const object = { type: "image", id: uuid(), frame: { x: 0, y: 0, width: size.width, height: size.height }, asset: name, altText: null };
        const origin = this.pasteOrigin();
        const spot = clearOrigin(object.frame.width, object.frame.height, origin.x, origin.y, this.page.objects.map((item) => item.frame).concat(made.map((item) => item.frame)));
        object.frame.x = spot.x;
        object.frame.y = spot.y;
        made.push(object);
      } else {
        const origin = this.pasteOrigin();
        const y = stackY ?? origin.y;
        made.push({
          type: "attachment", id: uuid(), asset: name, displayName: file.name || "Attachment",
          frame: { x: origin.x, y, width: 160, height: 64 },
        });
        stackY = y + 80;
      }
    }
    if (!made.length) return;
    this.selected = made.at(-1).id;
    this.commit((page) => { for (const object of made) page.objects.push(object); });
  }

  applyRun(kind, value) {
    const body = this.activeBody();
    if (!body) return;
    this.pullActive();
    const object = this.object(body.dataset.id);
    const sel = captureSelection(body);
    if (!object || !sel) return;
    const collapsed = sel.start.paragraph === sel.end.paragraph && sel.start.offset === sel.end.offset;
    if (collapsed) {
      const style = this.caretStyle(body);
      if (kind === "size") {
        if (value === BASE_FONT) delete style.fontSize;
        else style.fontSize = value;
      } else if (kind === "color") {
        const hex = safeHex(value);
        if (hex) style.colorHex = hex;
        else delete style.colorHex;
      } else style[kind] = !style[kind];
      this.insertTyping(body, style, object.paragraphs[sel.start.paragraph]?.heading || 0);
      this.hooks.onSelection?.();
      return;
    }
    const turnOn = kind === "bold" || kind === "italic" || kind === "underline" || kind === "strike" ? !rangeIsOn(object.paragraphs, sel, kind) : true;
    this.pendingRestore = { id: object.id, sel };
    this.commit((page) => {
      const target = page.objects.find((item) => item.id === object.id);
      mapRuns(target.paragraphs, sel, (style) => {
        if (kind === "size") {
          if (value === BASE_FONT) delete style.fontSize;
          else style.fontSize = value;
        } else if (kind === "color") {
          const hex = safeHex(value);
          if (hex) style.colorHex = hex;
          else delete style.colorHex;
        } else style[kind] = turnOn;
      });
    });
  }

  applyParagraph(fn) {
    const body = this.activeBody();
    if (!body) return;
    this.pullActive();
    const sel = captureSelection(body);
    const object = this.object(body.dataset.id);
    if (!sel || !object?.paragraphs.length) return;
    const [lo, hi] = paragraphRange(sel);
    this.pendingRestore = { id: object.id, sel };
    this.commit((page) => {
      const target = page.objects.find((item) => item.id === object.id);
      const end = Math.min(hi, target.paragraphs.length - 1);
      for (let index = Math.max(lo, 0); index <= end; index += 1) {
        fn(target.paragraphs[index]);
        clampParagraph(target.paragraphs[index]);
      }
    });
  }

  toggleList(kind) {
    if (this.activeBody()) {
      this.applyParagraph((paragraph) => { paragraph.list = paragraph.list === kind ? "none" : kind; });
      return;
    }
    if (!this.page) return;
    const origin = this.pasteOrigin();
    const box = {
      type: "text", id: uuid(),
      frame: { x: origin.x, y: origin.y, width: 320, height: MIN_TEXT_HEIGHT },
      paragraphs: [{ runs: [], indent: 0, heading: 0, list: kind, alignment: "left" }],
    };
    this.commit((page) => page.objects.push(box));
    this.focusBody(box.id);
  }

  indent(delta) {
    this.applyParagraph((paragraph) => { paragraph.indent += delta; });
  }

  caretStyle(body) {
    const node = document.getSelection()?.anchorNode;
    const host = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
    const row = host?.closest?.(".para");
    if (host && body.contains(host)) return styleOf(host, Number(row?.dataset.heading || 0));
    return { bold: false, italic: false, underline: false, strike: false, script: "normal" };
  }

  insertTyping(body, style, heading) {
    const selection = document.getSelection();
    if (!selection?.rangeCount) return;
    const span = el("span", "run");
    paint(span, style, heading);
    span.textContent = "\u200b";
    selection.getRangeAt(0).insertNode(span);
    const range = document.createRange();
    range.setStart(span.firstChild, span.firstChild.textContent.length);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  formattingState() {
    const body = this.activeBody();
    if (!body) return null;
    const sel = captureSelection(body);
    const host = document.getSelection()?.anchorNode?.parentElement?.closest?.(".para") || body.querySelector(".para");
    const style = this.caretStyle(body);
    if (sel && (sel.start.paragraph !== sel.end.paragraph || sel.start.offset !== sel.end.offset)) {
      const object = this.object(body.dataset.id);
      if (object) {
        style.bold = rangeIsOn(object.paragraphs, sel, "bold");
        style.italic = rangeIsOn(object.paragraphs, sel, "italic");
        style.underline = rangeIsOn(object.paragraphs, sel, "underline");
        style.strike = rangeIsOn(object.paragraphs, sel, "strike");
      }
    }
    return {
      ...style,
      fontSize: style.fontSize || BASE_FONT,
      heading: Number(host?.dataset.heading || 0),
      list: host?.dataset.list || "none",
      alignment: host?.dataset.align || "left",
    };
  }

  pullActive() {
    const body = this.activeBody();
    if (!body || this.composing) return;
    const object = this.object(body.dataset.id);
    if (object?.type === "text") object.paragraphs = parseBody(body);
  }

  onTextInput(id, body, linkify) {
    if (this.refreshing || this.composing) return;
    const object = this.object(id);
    if (!object) return;
    if (this.typingContainer !== id) {
      this.history.record(this.page);
      this.typingContainer = id;
    }
    this.justCreated = null;
    let paragraphs = parseBody(body);
    if (linkify) paragraphs = linkifyParagraphs(paragraphs);
    object.paragraphs = paragraphs;
    if (!isClean(body) || (linkify && JSON.stringify(paragraphs) !== body.dataset.sig)) {
      const sel = captureSelection(body);
      renderParagraphs(body, paragraphs);
      if (sel) restoreSelection(body, sel);
    } else body.dataset.sig = JSON.stringify(paragraphs);
    this.grow(body, object);
    this.fitCanvas();
    this.persist();
  }

  endEditing(id) {
    if (this.refreshing || this.sparing === id) return;
    const object = this.object(id);
    if (!object || !isEmptyText(object)) return;
    this.typingContainer = null;
    if (this.justCreated === id) {
      this.history.discardLast();
      this.justCreated = null;
    }
    this.page.objects = this.page.objects.filter((item) => item.id !== id);
    if (this.selected === id) this.selected = null;
    this.sync();
    this.persist();
    this.hooks.onSelection?.();
  }

  grow(body, object) {
    const height = Math.max(MIN_TEXT_HEIGHT, HANDLE + INSET * 2 + body.offsetHeight);
    object.frame.height = height;
    body.closest(".obj").style.height = `${height}px`;
  }

  focusBody(id) {
    const body = this.body(id);
    if (!body) return;
    body.focus();
    const range = document.createRange();
    range.selectNodeContents(body);
    range.collapse(false);
    const selection = document.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  sync(opts = {}) {
    if (!this.page) return;
    this.refreshing = true;
    const ids = new Set(this.page.objects.map((item) => item.id));
    for (const node of [...this.canvas.querySelectorAll(":scope > .obj")]) {
      if (!ids.has(node.dataset.id)) node.remove();
    }
    for (const [index, object] of this.page.objects.entries()) {
      let node = this.canvas.querySelector(`:scope > .obj[data-id="${CSS.escape(object.id)}"]`);
      if (!node) {
        node = this.build(object);
        this.canvas.append(node);
      }
      node.style.zIndex = String(index + 1);
      node.style.left = `${object.frame.x}px`;
      node.style.top = `${object.frame.y}px`;
      node.style.width = `${Math.max(object.frame.width, 1)}px`;
      node.style.height = `${Math.max(object.frame.height, 1)}px`;
      node.classList.toggle("selected", object.id === this.selected);
      if (object.type === "text") this.layoutText(node, object, opts.force);
      else if (object.type === "image") this.layoutImage(node, object);
      else if (object.type === "table") this.layoutTable(node, object);
      else this.layoutAttachment(node, object);
    }
    const order = this.page.objects.map((object) => this.canvas.querySelector(`:scope > .obj[data-id="${CSS.escape(object.id)}"]`));
    const current = [...this.canvas.querySelectorAll(":scope > .obj")];
    if (order.some((node, index) => node !== current[index])) {
      for (const node of order) if (node) this.canvas.append(node);
    }
    this.fitCanvas();
    this.refreshing = false;
    if (opts.focus) this.focusBody(opts.focus);
    if (this.pendingRestore) {
      const pending = this.pendingRestore;
      this.pendingRestore = null;
      const body = this.body(pending.id);
      if (body) {
        body.focus();
        restoreSelection(body, pending.sel);
      }
    }
  }

  fitCanvas() {
    const parent = this.canvas.parentElement;
    let maxX = 0;
    let maxY = 0;
    for (const object of this.page?.objects || []) {
      maxX = Math.max(maxX, object.frame.x + object.frame.width);
      maxY = Math.max(maxY, object.frame.y + object.frame.height);
    }
    this.canvas.style.width = `${Math.max(parent?.clientWidth || 0, maxX + 400)}px`;
    this.canvas.style.height = `${Math.max(parent?.clientHeight || 0, maxY + 400)}px`;
  }

  layoutText(node, object, force) {
    const body = node.querySelector(".body");
    const editing = document.activeElement === body;
    if ((force || !editing) && (force || body.dataset.sig !== JSON.stringify(object.paragraphs))) {
      renderParagraphs(body, object.paragraphs);
    }
    node.classList.toggle("editing", editing);
    if (!editing) {
      const height = Math.max(MIN_TEXT_HEIGHT, HANDLE + INSET * 2 + body.offsetHeight);
      if (Math.abs(object.frame.height - height) > 0.5) {
        object.frame.height = height;
        node.style.height = `${height}px`;
      }
    }
  }

  layoutImage(node, object) {
    const image = node.querySelector("img");
    image.alt = object.altText || "";
    if (image.dataset.asset !== object.asset) {
      image.dataset.asset = object.asset;
      image.removeAttribute("src");
      this.hooks.loadAsset(object.asset).then((bytes) => {
        if (!bytes || image.dataset.asset !== object.asset) return;
        let url = this.assets.get(object.asset);
        if (!url) {
          url = URL.createObjectURL(new Blob([bytes]));
          this.assets.set(object.asset, url);
        }
        image.src = url;
      }).catch(() => {});
    }
    for (const corner of node.querySelectorAll(".corner")) corner.hidden = object.id !== this.selected;
  }

  layoutTable(node, object) {
    const table = document.createElement("table");
    table.className = object.bordersVisible ? "grid bordered" : "grid";
    for (const row of object.rows || []) {
      const tr = document.createElement("tr");
      row.forEach((cell, column) => {
        const td = document.createElement("td");
        td.style.width = `${object.columnWidths?.[column] || 80}px`;
        const inner = el("div", "cell");
        fillReadonly(inner, cell.paragraphs || []);
        td.append(inner);
        tr.append(td);
      });
      table.append(tr);
    }
    const content = node.querySelector(".readonly");
    content.replaceChildren(table);
  }

  layoutAttachment(node, object) {
    node.querySelector(".attach-name").textContent = object.displayName || "Attachment";
    const ext = (object.asset || "").includes(".") ? object.asset.split(".").pop() : "";
    node.querySelector(".attach-ext").textContent = (ext || "file").toUpperCase();
  }

  build(object) {
    const node = el("article", `obj ${object.type}`);
    node.dataset.id = object.id;
    node.addEventListener("pointerdown", (event) => event.stopPropagation());
    if (object.type === "text") {
      const handle = el("div", "handle");
      handle.title = "Drag to move";
      const body = el("div", "body");
      body.contentEditable = "true";
      body.spellcheck = true;
      const grip = el("div", "grip");
      grip.title = "Drag to change width";
      node.append(handle, body, grip);
      this.wireText(node, object.id, handle, body, grip);
      return node;
    }
    const content = el("div", "readonly");
    const handle = el("div", "handle");
    handle.title = "Drag to move";
    node.append(content, handle);
    if (object.type === "image") {
      const image = document.createElement("img");
      image.alt = "";
      image.draggable = false;
      content.append(image);
      for (const corner of CORNERS) {
        const knob = el("div", `corner ${corner}`);
        node.append(knob);
        this.wireCorner(object.id, knob, corner);
      }
    } else if (object.type === "attachment") {
      content.append(el("div", "attach-ext"), el("div", "attach-name"));
    }
    this.wireMove(object.id, handle);
    content.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      this.beginDrag(object.id);
      this.endDrag();
    });
    return node;
  }

  wireText(node, id, handle, body, grip) {
    body.dataset.id = id;
    body.addEventListener("focus", () => {
      if (this.refreshing) return;
      node.classList.add("editing");
      if (this.selected) {
        this.selected = null;
        this.sync();
      }
      this.hooks.onSelection?.();
    });
    body.addEventListener("blur", () => {
      node.classList.remove("editing");
      if (this.refreshing) return;
      const object = this.object(id);
      if (!object) return;
      object.paragraphs = parseBody(body);
      if (this.sparing === id) return;
      if (isEmptyText(object)) {
        this.endEditing(id);
        this.hooks.onSelection?.();
        return;
      }
      const linked = linkifyParagraphs(object.paragraphs);
      if (JSON.stringify(linked) !== JSON.stringify(object.paragraphs)) {
        object.paragraphs = linked;
        renderParagraphs(body, linked);
        this.grow(body, object);
      }
      this.persist();
      this.hooks.onSelection?.();
    });
    body.addEventListener("beforeinput", (event) => {
      if (event.inputType === "historyUndo" || event.inputType === "historyRedo") event.preventDefault();
    });
    body.addEventListener("input", (event) => {
      const linkify = event.inputType === "insertFromPaste" || /\s$/.test(body.innerText);
      this.onTextInput(id, body, linkify);
    });
    body.addEventListener("compositionstart", () => { this.composing = true; });
    body.addEventListener("compositionend", () => {
      this.composing = false;
      this.onTextInput(id, body, false);
    });
    body.addEventListener("keydown", (event) => this.onTextKey(event, id, body));
    body.addEventListener("click", (event) => {
      const link = event.target.closest?.("[data-link]");
      if (!link || !(event.metaKey || event.ctrlKey)) return;
      const url = safeURL(link.dataset.link);
      if (!url) return;
      event.preventDefault();
      window.open(url, "_blank", "noopener");
    });
    this.wireMove(id, handle);
    this.wireWidth(id, grip);
  }

  onTextKey(event, id, body) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.pullActive();
      const sel = captureSelection(body);
      const object = this.object(id);
      if (!sel || !object) return;
      if (this.typingContainer !== id) {
        this.history.record(this.page);
        this.typingContainer = id;
      }
      this.justCreated = null;
      const at = sel.start.paragraph < sel.end.paragraph || (sel.start.paragraph === sel.end.paragraph && sel.start.offset <= sel.end.offset) ? sel.start : sel.end;
      if (!object.paragraphs.length) object.paragraphs.push({ runs: [], indent: 0, heading: 0, list: "none", alignment: "left" });
      splitParagraph(object.paragraphs, at.paragraph, at.offset);
      this.pendingRestore = { id, sel: { start: { paragraph: at.paragraph + 1, offset: 0 }, end: { paragraph: at.paragraph + 1, offset: 0 } } };
      this.sync({ force: true });
      this.persist();
      return;
    }
    if (event.key !== "Backspace") return;
    const sel = captureSelection(body);
    if (!sel || sel.start.paragraph !== sel.end.paragraph || sel.start.offset !== sel.end.offset || sel.start.offset !== 0 || sel.start.paragraph === 0) return;
    event.preventDefault();
    this.pullActive();
    const object = this.object(id);
    if (!object) return;
    const at = runLength(object.paragraphs[sel.start.paragraph - 1]);
    if (this.typingContainer !== id) {
      this.history.record(this.page);
      this.typingContainer = id;
    }
    this.justCreated = null;
    mergeParagraph(object.paragraphs, sel.start.paragraph);
    this.pendingRestore = {
      id,
      sel: { start: { paragraph: sel.start.paragraph - 1, offset: at }, end: { paragraph: sel.start.paragraph - 1, offset: at } },
    };
    this.sync({ force: true });
    this.persist();
  }

  wireMove(id, handle) {
    handle.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      this.trackPointer(handle, event, (dx, dy, moved) => {
        if (!moved) return;
        this.drag((page) => {
          const object = page.objects.find((item) => item.id === id);
          const start = this.dragStart.objects.find((item) => item.id === id);
          if (!object || !start) return;
          object.frame.x = start.frame.x + dx;
          object.frame.y = start.frame.y + dy;
        });
      });
    });
  }

  wireWidth(id, grip) {
    grip.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      this.trackPointer(grip, event, (dx, _dy, moved) => {
        if (!moved) return;
        this.drag((page) => {
          const object = page.objects.find((item) => item.id === id);
          const start = this.dragStart.objects.find((item) => item.id === id);
          if (!object || !start) return;
          object.frame.width = Math.max(MIN_TEXT_WIDTH, start.frame.width + dx);
        });
      });
    });
  }

  wireCorner(id, knob, corner) {
    knob.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      this.trackPointer(knob, event, (dx, dy, moved) => {
        if (!moved) return;
        this.drag((page) => {
          const object = page.objects.find((item) => item.id === id);
          const start = this.dragStart.objects.find((item) => item.id === id);
          if (!object || start?.type !== "image") return;
          object.frame = scaledImageFrame(start.frame, corner, dx, dy);
        });
      });
    });
  }

  trackPointer(node, event, onMove) {
    const id = node.closest(".obj")?.dataset.id;
    this.beginDrag(id);
    const originX = event.clientX;
    const originY = event.clientY;
    const move = (ev) => {
      const dx = ev.clientX - originX;
      const dy = ev.clientY - originY;
      onMove(dx, dy, this.dragRecorded || Math.hypot(dx, dy) >= 2);
    };
    const up = () => {
      node.removeEventListener("pointermove", move);
      this.endDrag();
    };
    node.setPointerCapture?.(event.pointerId);
    node.addEventListener("pointermove", move);
    node.addEventListener("pointerup", up, { once: true });
    node.addEventListener("pointercancel", up, { once: true });
  }
}
