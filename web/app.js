// NoteCanvas in the browser. The notebook folder is the Mac app's package.

import {
  INK, SWATCHES, findFolder, findItem, flattenPages, parentOf, safeHex, sameId, sectionOf,
} from "./model.js";
import {
  Package, canPickDirectory, forgetHandle, hasPermission, pickDirectory, rememberHandle,
  rememberedHandle, requestPermission,
} from "./store.js";
import { PageEditor } from "./canvas.js";

const $ = (id) => document.getElementById(id);

const app = $("app");
const banner = $("banner");
const notebookName = $("notebook-name");
const sectionPopup = $("section-popup");
const nav = $("nav");
const pageTitle = $("page-title");
const menu = $("menu");
const dropLine = $("drop-line");
const imageInput = $("image-input");
const reopenBtn = $("reopen-btn");

const state = {
  pkg: null,
  section: 0,
  navId: null,
  collapsed: new Set(),
  renaming: null,
  drop: null,
  remembered: null,
};

const editor = new PageEditor($("canvas"), {
  onPersist: (page) => savePage(page),
  storeAsset: (data, ext) => state.pkg.addAsset(data, ext),
  loadAsset: (name) => state.pkg.loadAsset(name),
  onSelection: () => refreshFormat(),
});

function showBanner(text) {
  banner.hidden = !text;
  banner.textContent = text || "";
}

function currentSection() {
  return state.pkg?.notebook.sections[state.section] || null;
}

function destinationFolder() {
  const section = currentSection();
  if (!section || !state.navId) return null;
  if (findFolder(section.items, state.navId)) return state.navId;
  const place = parentOf(section.items, state.navId);
  return place.found ? place.parent : null;
}

async function savePage(page) {
  try {
    await state.pkg.savePage(page);
    showBanner("");
    renderNav();
    return true;
  } catch (error) {
    showBanner(error.message || "The page could not be saved.");
    return false;
  }
}

function setNotebookChrome(open) {
  app.classList.toggle("no-notebook", !open);
  app.classList.toggle("has-notebook", open);
  notebookName.disabled = !open;
  const locked = currentSection()?.locked;
  for (const id of ["add-page", "add-folder", "remove-item", "section-menu-btn"]) $(id).disabled = !open || !!locked && id !== "section-menu-btn";
  if (!open) {
    pageTitle.value = "";
    pageTitle.disabled = true;
    editor.discard();
  }
}

async function usePackage(pkg, pageId) {
  state.pkg = pkg;
  state.section = 0;
  state.navId = null;
  state.collapsed = new Set();
  notebookName.value = pkg.notebook.name;
  setNotebookChrome(true);
  renderSections();
  renderNav();
  const section = pkg.notebook.sections[0];
  const first = pageId || flattenPages(section?.items || [])[0]?.id;
  if (first) await showPage(first);
  else {
    editor.discard();
    pageTitle.value = "";
    pageTitle.disabled = true;
  }
  refreshFormat();
}

async function openHandle(handle) {
  const pkg = await Package.open(handle);
  await rememberHandle(handle);
  state.remembered = handle;
  await usePackage(pkg);
}

async function chooseNotebook() {
  const handle = await pickDirectory("notecanvas-notebook");
  await openHandle(handle);
}

async function createNotebook() {
  const parent = await pickDirectory("notecanvas-parent");
  const name = window.prompt("Name this notebook", "Untitled");
  if (!name || !name.trim()) return;
  const made = await Package.create(parent, name);
  await rememberHandle(made.pkg.root);
  state.remembered = made.pkg.root;
  await usePackage(made.pkg, made.page.id);
}

function renderSections() {
  const notebook = state.pkg?.notebook;
  sectionPopup.replaceChildren();
  if (!notebook) return;
  notebook.sections.forEach((section, index) => {
    const option = document.createElement("option");
    option.value = String(index);
    option.textContent = section.locked ? `${section.name} (locked)` : section.name;
    sectionPopup.append(option);
  });
  sectionPopup.value = String(state.section);
}

function folderIcon(color) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 20 16");
  svg.setAttribute("class", "mark");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("fill", safeHex(color) || INK);
  path.setAttribute("d", "M1 3.5A1.5 1.5 0 0 1 2.5 2h4l1.5 2H17.5A1.5 1.5 0 0 1 19 5.5v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 1 13.5v-10z");
  svg.append(path);
  return svg;
}

function visibleRows(items, depth, parentId) {
  const rows = [];
  items.forEach((item, index) => {
    rows.push({ item, depth, parentId, index });
    if (item.kind === "folder" && !state.collapsed.has(item.id)) {
      rows.push(...visibleRows(item.children, depth + 1, item.id));
    }
  });
  return rows;
}

function renderNav() {
  const section = currentSection();
  nav.replaceChildren();
  if (!section) return;
  if (section.locked) {
    const note = document.createElement("div");
    note.className = "nav-empty";
    note.textContent = "This section is locked. Unlock it in the Mac app.";
    nav.append(note);
    return;
  }
  const rows = visibleRows(section.items, 0, null);
  if (!rows.length) {
    const note = document.createElement("div");
    note.className = "nav-empty";
    note.textContent = "No pages yet";
    nav.append(note);
    return;
  }
  for (const row of rows) nav.append(renderRow(row));
}

function renderRow(row) {
  const { item, depth } = row;
  const line = document.createElement("div");
  line.className = `nav-row ${item.kind}`;
  line.style.paddingLeft = `${depth * 16}px`;
  line.dataset.id = item.id;
  line.setAttribute("role", "treeitem");
  if (state.navId && sameId(state.navId, item.id)) line.classList.add("selected");
  if (state.drop?.mode === "inside" && state.drop.parent && sameId(state.drop.parent, item.id)) line.classList.add("drop-inside");
  const twist = document.createElement("button");
  twist.type = "button";
  twist.className = "twist";
  twist.tabIndex = -1;
  if (item.kind === "folder") {
    twist.textContent = state.collapsed.has(item.id) ? "▸" : "▾";
    twist.addEventListener("click", (event) => {
      event.stopPropagation();
      if (state.collapsed.has(item.id)) state.collapsed.delete(item.id);
      else state.collapsed.add(item.id);
      renderNav();
    });
  } else twist.style.visibility = "hidden";
  line.append(twist);
  if (item.kind === "folder") line.append(folderIcon(item.colorHex));
  if (state.renaming && sameId(state.renaming, item.id) && item.kind === "folder") {
    const input = document.createElement("input");
    input.className = "rename";
    input.value = item.name;
    input.addEventListener("mousedown", (event) => event.stopPropagation());
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") input.blur();
      if (event.key === "Escape") { state.renaming = null; renderNav(); }
    });
    input.addEventListener("blur", () => commitRename(item.id, input.value));
    line.append(input);
    queueMicrotask(() => { input.focus(); input.select(); });
  } else {
    const title = document.createElement("span");
    title.className = "nav-title";
    title.textContent = item.kind === "folder" ? item.name : item.title;
    title.style.color = safeHex(item.colorHex) || INK;
    line.append(title);
  }
  if (item.kind === "page" || state.renaming == null || !sameId(state.renaming, item.id)) line.draggable = true;
  line.addEventListener("click", () => selectRow(item));
  line.addEventListener("dblclick", () => { if (item.kind === "folder") { state.renaming = item.id; renderNav(); } });
  line.addEventListener("contextmenu", (event) => { event.preventDefault(); selectRow(item, { keepPage: true }); openItemMenu(item, event.clientX, event.clientY); });
  line.addEventListener("dragstart", (event) => {
    event.dataTransfer.setData("text/plain", item.id);
    event.dataTransfer.effectAllowed = "move";
    state.dragging = item.id;
  });
  line.addEventListener("dragover", (event) => onDragOver(event, row, line));
  line.addEventListener("drop", (event) => onDrop(event));
  line.addEventListener("dragend", () => { state.dragging = null; state.drop = null; dropLine.hidden = true; renderNav(); });
  return line;
}

async function selectRow(item, opts = {}) {
  state.navId = item.id;
  if (item.kind === "page" && !opts.keepPage) await showPage(item.id);
  else renderNav();
}

async function commitRename(id, value) {
  if (state.renaming == null) return;
  state.renaming = null;
  const name = value.trim() || "Folder";
  try {
    await state.pkg.renameFolder(id, state.section, name);
  } catch (error) {
    showBanner(error.message);
  }
  renderNav();
}

function canDrop(section, movingId, parent) {
  if (!parent) return true;
  if (sameId(parent, movingId)) return false;
  const moving = findItem(section.items, movingId);
  if (moving?.kind === "folder" && findItem(moving.children, parent)) return false;
  return !!findFolder(section.items, parent);
}

function onDragOver(event, row, line) {
  if (!state.dragging) return;
  const section = currentSection();
  if (!section) return;
  event.preventDefault();
  const rect = line.getBoundingClientRect();
  const ratio = (event.clientY - rect.top) / Math.max(rect.height, 1);
  let parent = row.parentId;
  let index = row.index;
  let mode = "before";
  if (row.item.kind === "folder" && ratio > 0.28 && ratio < 0.72) {
    parent = row.item.id;
    index = row.item.children.length;
    mode = "inside";
  } else if (ratio >= 0.5) {
    index = row.index + 1;
    mode = "after";
  }
  if (!canDrop(section, state.dragging, parent)) {
    event.dataTransfer.dropEffect = "none";
    state.drop = null;
    dropLine.hidden = true;
    return;
  }
  event.dataTransfer.dropEffect = "move";
  state.drop = { parent, index, mode };
  line.classList.toggle("drop-inside", mode === "inside");
  if (mode === "inside") dropLine.hidden = true;
  else {
    dropLine.hidden = false;
    dropLine.style.left = `${rect.left + 8}px`;
    dropLine.style.width = `${Math.max(rect.width - 16, 24)}px`;
    dropLine.style.top = `${mode === "before" ? rect.top : rect.bottom - 1}px`;
  }
}

async function onDrop(event) {
  event.preventDefault();
  dropLine.hidden = true;
  const drop = state.drop;
  const id = state.dragging;
  state.dragging = null;
  state.drop = null;
  if (!drop || !id) { renderNav(); return; }
  try {
    const moved = await state.pkg.moveItem(id, state.section, drop.parent, drop.index);
    if (drop.parent) state.collapsed.delete(drop.parent);
    if (!moved) showBanner("That item cannot move there.");
  } catch (error) {
    showBanner(error.message);
  }
  renderNav();
}

async function showPage(id) {
  if (!state.pkg) return;
  if (editor.page && sameId(editor.page.id, id)) {
    state.navId = id;
    renderNav();
    return;
  }
  const ok = await editor.flush();
  if (!ok) {
    showBanner("This page could not be saved, so it stays open.");
    return;
  }
  try {
    const page = await state.pkg.loadPage(id);
    state.navId = id;
    pageTitle.disabled = false;
    pageTitle.value = page.title;
    await editor.load(page);
    renderNav();
    refreshFormat();
    showBanner("");
  } catch (error) {
    showBanner(error.message);
  }
}

function closeMenu() {
  menu.hidden = true;
  menu.replaceChildren();
}

function openMenu(x, y, entries) {
  menu.replaceChildren();
  for (const entry of entries) {
    if (entry.separator) { menu.append(document.createElement("hr")); continue; }
    const button = document.createElement("button");
    button.type = "button";
    button.role = "menuitem";
    if (entry.swatch) {
      const dot = document.createElement("span");
      dot.className = "swatch";
      dot.style.background = entry.swatch;
      button.append(dot);
    } else {
      const mark = document.createElement("span");
      mark.className = "check";
      mark.textContent = entry.checked ? "✓" : "";
      button.append(mark);
    }
    button.append(document.createTextNode(entry.label));
    button.disabled = !!entry.disabled;
    button.addEventListener("click", () => { closeMenu(); entry.action(); });
    menu.append(button);
  }
  menu.hidden = false;
  menu.style.left = `${Math.min(x, window.innerWidth - menu.offsetWidth - 8)}px`;
  menu.style.top = `${Math.min(y, window.innerHeight - 8)}px`;
  const rect = menu.getBoundingClientRect();
  if (rect.bottom > window.innerHeight) menu.style.top = `${Math.max(8, y - rect.height)}px`;
}

function colorEntries(id, current) {
  return SWATCHES.map((swatch, index) => ({
    label: swatch.name,
    swatch: swatch.hex,
    checked: (swatch.hex || null) === (current || null),
    separator: false,
    action: () => paintItem(id, swatch.hex),
    ...(index === SWATCHES.length - 1 ? {} : {}),
  })).flatMap((entry, index) => (index === SWATCHES.length - 1 ? [{ separator: true }, entry] : [entry]));
}

function openItemMenu(item, x, y) {
  const entries = [];
  if (item.kind === "folder") entries.push({ label: "Rename Folder", action: () => { state.renaming = item.id; renderNav(); } });
  entries.push(...colorEntries(item.id, item.colorHex));
  entries.push({ separator: true });
  const others = state.pkg.notebook.sections.filter((section) => sectionOf(state.pkg.notebook, item.id) !== state.pkg.notebook.sections.indexOf(section) && !section.locked);
  if (state.pkg.notebook.sections.length > 1) {
    for (const section of state.pkg.notebook.sections) {
      const index = state.pkg.notebook.sections.indexOf(section);
      if (index === state.section || section.locked) continue;
      entries.push({ label: `Move to ${section.name}`, action: () => moveToSection(item.id, index) });
    }
    if (others.length) entries.push({ separator: true });
  }
  if (item.kind === "folder") entries.push({ label: "Remove Folder", action: () => dissolve(item) });
  else entries.push({ label: "Delete Page", action: () => deletePage(item) });
  openMenu(x, y, entries);
}

function openSectionMenu(x, y) {
  const notebook = state.pkg.notebook;
  const section = currentSection();
  openMenu(x, y, [
    { label: "New Section", action: () => addSection() },
    { label: "Rename Section", action: () => renameSection() },
    { separator: true },
    { label: "Move Up", disabled: state.section === 0, action: () => shiftSection(-1) },
    { label: "Move Down", disabled: state.section >= notebook.sections.length - 1, action: () => shiftSection(1) },
    { separator: true },
    { label: "Delete Section", disabled: notebook.sections.length < 2 || section.locked, action: () => deleteSection() },
  ]);
}

async function paintItem(id, hex) {
  try {
    await state.pkg.setColor(id, state.section, hex);
    renderNav();
  } catch (error) { showBanner(error.message); }
}

async function moveToSection(id, index) {
  try {
    await state.pkg.relocate(id, state.section, index);
    if (editor.page && sameId(editor.page.id, id)) state.navId = null;
    renderNav();
  } catch (error) { showBanner(error.message); }
}

async function addSection() {
  try {
    const section = await state.pkg.addSection("New Section");
    state.section = state.pkg.notebook.sections.findIndex((item) => item.id === section.id);
    renderSections();
    renderNav();
    renameSection();
  } catch (error) { showBanner(error.message); }
}

function renameSection() {
  const section = currentSection();
  if (!section) return;
  const name = window.prompt("Section name", section.name);
  if (name == null) return;
  const trimmed = name.trim() || "Section";
  state.pkg.renameSection(section.id, trimmed).then(() => renderSections()).catch((error) => showBanner(error.message));
}

async function shiftSection(delta) {
  const section = currentSection();
  const from = state.section;
  const target = from + delta + (delta > 0 ? 1 : 0);
  try {
    await state.pkg.moveSection(section.id, target);
    state.section = state.pkg.notebook.sections.findIndex((item) => item.id === section.id);
    renderSections();
    renderNav();
  } catch (error) { showBanner(error.message); }
}

async function deleteSection() {
  const section = currentSection();
  if (!section) return;
  const count = flattenPages(section.items).length;
  const message = count
    ? `Delete the section “${section.name}”? Its ${count} page ${count === 1 ? "file stays" : "files stay"} in the notebook folder.`
    : `Delete the section “${section.name}”?`;
  if (!window.confirm(message)) return;
  const openGoes = editor.page && sectionOf(state.pkg.notebook, editor.page.id) === state.section && flattenPages(section.items).some((page) => sameId(page.id, editor.page.id));
  try {
    await state.pkg.deleteSection(section.id);
    if (openGoes) { editor.discard(); pageTitle.value = ""; pageTitle.disabled = true; }
    state.section = 0;
    state.navId = null;
    renderSections();
    renderNav();
    const first = flattenPages(currentSection()?.items || [])[0];
    if (openGoes && first) await showPage(first.id);
  } catch (error) { showBanner(error.message); }
}

async function addPage() {
  if (!currentSection() || currentSection().locked) return;
  try {
    await editor.flush();
    const page = await state.pkg.addPage("Untitled Page", state.section, destinationFolder());
    await showPage(page.id);
  } catch (error) { showBanner(error.message); }
}

async function addFolder() {
  if (!currentSection() || currentSection().locked) return;
  try {
    const parent = destinationFolder();
    const id = await state.pkg.addFolder("New Folder", state.section, parent);
    state.navId = id;
    state.renaming = id;
    if (parent) state.collapsed.delete(parent);
    renderNav();
  } catch (error) { showBanner(error.message); }
}

async function removeSelected() {
  const section = currentSection();
  const item = section && state.navId ? findItem(section.items, state.navId) : null;
  if (!item) return;
  if (item.kind === "folder") await dissolve(item);
  else await deletePage(item);
}

async function dissolve(item) {
  if (!window.confirm(`Remove “${item.name}”? Pages and folders inside it stay in this section.`)) return;
  try {
    await state.pkg.dissolveFolder(item.id, state.section);
    if (sameId(state.navId, item.id)) state.navId = null;
    renderNav();
  } catch (error) { showBanner(error.message); }
}

async function deletePage(item) {
  const title = editor.page && sameId(editor.page.id, item.id) ? editor.page.title : item.title;
  if (!window.confirm(`Delete “${title}”? The page will be removed from the notebook. The file stays in the folder, because the browser cannot move it to the Trash.`)) return;
  try {
    if (editor.page && sameId(editor.page.id, item.id)) {
      editor.discard();
      pageTitle.value = "";
      pageTitle.disabled = true;
    }
    await state.pkg.deletePage(item.id);
    state.navId = null;
    renderNav();
    const first = flattenPages(currentSection()?.items || [])[0];
    if (first) await showPage(first.id);
  } catch (error) { showBanner(error.message); }
}

function refreshFormat() {
  const format = editor.formattingState();
  for (const [id, key] of [["bold-btn", "bold"], ["italic-btn", "italic"], ["underline-btn", "underline"], ["strike-btn", "strike"]]) {
    $(id).setAttribute("aria-pressed", format?.[key] ? "true" : "false");
  }
  if (format) {
    $("size-select").value = String(format.fontSize);
    $("heading-select").value = String(format.heading);
    if (format.colorHex) $("color-input").value = format.colorHex;
  }
  $("undo-btn").disabled = !editor.history.canUndo;
  $("redo-btn").disabled = !editor.history.canRedo;
  const objectSelected = !!editor.selected && !editor.editing;
  $("front-btn").disabled = !objectSelected;
  $("back-btn").disabled = !objectSelected;
}

function holdFormat(event) {
  if (event.target.closest("select, input[type=color]")) editor.rememberSelection();
  else if (event.target.closest("button")) event.preventDefault();
}

function runFormat(fn) {
  editor.recallSelection();
  fn();
}

function bindFormat() {
  $("formatbar").addEventListener("mousedown", holdFormat);
  $("bold-btn").addEventListener("click", () => editor.applyRun("bold"));
  $("italic-btn").addEventListener("click", () => editor.applyRun("italic"));
  $("underline-btn").addEventListener("click", () => editor.applyRun("underline"));
  $("strike-btn").addEventListener("click", () => editor.applyRun("strike"));
  $("bullet-btn").addEventListener("click", () => editor.toggleList("bullet"));
  $("number-btn").addEventListener("click", () => editor.toggleList("numbered"));
  $("align-left").addEventListener("click", () => editor.applyParagraph((paragraph) => { paragraph.alignment = "left"; }));
  $("align-center").addEventListener("click", () => editor.applyParagraph((paragraph) => { paragraph.alignment = "center"; }));
  $("align-right").addEventListener("click", () => editor.applyParagraph((paragraph) => { paragraph.alignment = "right"; }));
  $("indent-more").addEventListener("click", () => editor.indent(1));
  $("indent-less").addEventListener("click", () => editor.indent(-1));
  $("front-btn").addEventListener("click", () => editor.bringToFront());
  $("back-btn").addEventListener("click", () => editor.sendToBack());
  $("undo-btn").addEventListener("click", () => editor.undo());
  $("redo-btn").addEventListener("click", () => editor.redo());
  $("size-select").addEventListener("change", () => runFormat(() => editor.applyRun("size", Number($("size-select").value))));
  $("heading-select").addEventListener("change", () => runFormat(() => editor.applyParagraph((paragraph) => { paragraph.heading = Number($("heading-select").value); })));
  $("color-input").addEventListener("change", () => runFormat(() => editor.applyRun("color", $("color-input").value)));
  $("image-btn").addEventListener("click", () => { if (editor.page) imageInput.click(); });
  imageInput.addEventListener("change", () => {
    const files = [...imageInput.files];
    imageInput.value = "";
    editor.insertFiles(files).catch((error) => showBanner(error.message));
  });
}

function bindChrome() {
  const guard = (fn) => async () => {
    try { await fn(); } catch (error) {
      if (error?.name === "AbortError") return;
      showBanner(error.message || "Something went wrong.");
    }
  };
  $("open-btn").addEventListener("click", guard(chooseNotebook));
  $("welcome-open").addEventListener("click", guard(chooseNotebook));
  $("new-btn").addEventListener("click", guard(createNotebook));
  $("welcome-new").addEventListener("click", guard(createNotebook));
  reopenBtn.addEventListener("click", guard(async () => {
    if (!state.remembered) return;
    if (!await requestPermission(state.remembered)) {
      showBanner("NoteCanvas needs permission to open that folder.");
      return;
    }
    await openHandle(state.remembered);
  }));
  $("add-page").addEventListener("click", () => addPage());
  $("add-folder").addEventListener("click", () => addFolder());
  $("remove-item").addEventListener("click", () => removeSelected());
  $("section-menu-btn").addEventListener("click", (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    openSectionMenu(rect.left, rect.bottom + 4);
  });
  sectionPopup.addEventListener("change", () => {
    state.section = Number(sectionPopup.value);
    state.navId = null;
    const locked = !!currentSection()?.locked;
    $("add-page").disabled = locked;
    $("add-folder").disabled = locked;
    renderNav();
  });
  notebookName.addEventListener("change", async () => {
    if (!state.pkg) return;
    const typed = notebookName.value.trim();
    if (!typed) { notebookName.value = state.pkg.notebook.name; return; }
    try { await state.pkg.renameNotebook(typed); } catch (error) {
      notebookName.value = state.pkg.notebook.name;
      showBanner(error.message);
    }
  });
  pageTitle.addEventListener("change", () => editor.setTitle(pageTitle.value));
  pageTitle.addEventListener("keydown", (event) => { if (event.key === "Enter") pageTitle.blur(); });
  $("sidebar-btn").addEventListener("click", () => {
    const hidden = app.classList.toggle("sidebar-hidden");
    // A view preference only. Note text is never written to localStorage.
    localStorage.setItem("notecanvas.sidebarHidden", hidden ? "1" : "0");
  });
  document.addEventListener("pointerdown", (event) => {
    if (!menu.hidden && !menu.contains(event.target) && event.target.id !== "section-menu-btn") closeMenu();
  });
  window.addEventListener("blur", () => { editor.clipboardFresh = false; });
  document.addEventListener("selectionchange", () => { if (editor.editing) refreshFormat(); });
  document.addEventListener("keydown", onKey, true);
  document.addEventListener("copy", onCopy, true);
  document.addEventListener("paste", onPaste, true);
  window.addEventListener("resize", () => editor.fitCanvas());
}

function typingField(target) {
  return target?.matches?.("input, textarea") || (target?.isContentEditable && !target.classList.contains("body"));
}

function onKey(event) {
  if (typingField(event.target)) return;
  const meta = event.metaKey || event.ctrlKey;
  const key = event.key.toLowerCase();
  if (meta && key === "z") {
    event.preventDefault();
    if (event.shiftKey) editor.redo();
    else editor.undo();
    refreshFormat();
  } else if (meta && key === "y") {
    event.preventDefault();
    editor.redo();
    refreshFormat();
  } else if (meta && editor.editing && key === "b") {
    event.preventDefault();
    editor.applyRun("bold");
  } else if (meta && editor.editing && key === "i") {
    event.preventDefault();
    editor.applyRun("italic");
  } else if (meta && editor.editing && key === "u") {
    event.preventDefault();
    editor.applyRun("underline");
  } else if ((event.key === "Backspace" || event.key === "Delete") && editor.selected && !editor.editing) {
    event.preventDefault();
    editor.deleteSelected();
  }
}

function onCopy(event) {
  if (typingField(event.target) || editor.editing || !editor.selected) {
    editor.clipboardFresh = false;
    return;
  }
  const json = editor.copySelected();
  if (!json) return;
  event.preventDefault();
  event.clipboardData.setData("application/x-notecanvas-object", json);
  event.clipboardData.setData("text/plain", "");
}

function onPaste(event) {
  if (!state.pkg || !editor.page || typingField(event.target)) return;
  const data = event.clipboardData;
  const custom = data.getData("application/x-notecanvas-object");
  const image = [...data.items].some((item) => item.type.startsWith("image/"));
  const files = data.files?.length;
  if (editor.editing && !custom && !image && !files && !(editor.clipboardFresh && !data.getData("text/plain"))) return;
  event.preventDefault();
  editor.pasteFrom(data).catch((error) => showBanner(error.message));
}

async function restoreLast() {
  if (!canPickDirectory()) {
    $("browser-note").hidden = false;
    $("open-btn").disabled = true;
    $("new-btn").disabled = true;
    $("welcome-open").disabled = true;
    $("welcome-new").disabled = true;
    return;
  }
  const handle = await rememberedHandle();
  if (!handle) return;
  state.remembered = handle;
  if (await hasPermission(handle)) {
    try { await openHandle(handle); return; } catch (error) { showBanner(error.message); }
  }
  reopenBtn.hidden = false;
  reopenBtn.textContent = `Reopen ${handle.name}`;
}

if (localStorage.getItem("notecanvas.sidebarHidden") === "1") app.classList.add("sidebar-hidden");
bindFormat();
bindChrome();
setNotebookChrome(false);
restoreLast();
