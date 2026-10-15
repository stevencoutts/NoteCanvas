# NoteCanvas locked sections, format version 2

Status: **draft for review**. Nothing here is implemented yet. This document amends [the version 1 encrypted notebook format](encryption-spec.md) and assumes you have read it. Reference test vectors are in `encryption-section-vectors.json`, produced by `tools/make-section-vectors.py`, which builds on `tools/make-vectors.py`.

## What it adds

A section of an encrypted notebook can be **locked**: it gets its own random key, its own passphrase and its own recovery key. Someone who can open the notebook, for example because the Notebook Key is cached in the Keychain on a shared or borrowed Mac, still cannot read a locked section until they supply that section's passphrase.

Example: in a notebook with sections `Home`, `Test Section` and `Block`, lock `Block` (customer material) and leave the others open.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Unit of locking | A section. Not a folder, not a page. | A folder's contents sit inside the section manifest, and moving a page across a lock boundary means re-encrypting it. Sections give nearly all the benefit. A later version can apply the same mechanism to a folder. |
| Where it is allowed | Only inside an encrypted notebook. | One layout, not a hybrid of plain and encrypted files. The section list is hidden from the storage provider too. Day to day the Notebook Key can still come from the Keychain, so the notebook itself opens without a prompt. |
| Is a locked section encrypted twice? | No. Its pages and assets are encrypted under the Section Key only. | The Notebook Key must not be a way into a locked section. |
| Can the notebook passphrase also open a locked section? | No. | That would defeat the lock. Each locked section has its own recovery key, shown once. Losing both the passphrase and the recovery key loses the section. |
| Who can hold a section's slots? | Any number of passphrase slots, plus the recovery slot. | Lets one section be shared later with another person without sharing the rest. Sharing is still outside the goals of this version. |

## Threat model additions

| Attacker | Outcome |
|---|---|
| Holds the Notebook Key or notebook passphrase but not the section's passphrase or recovery key | Sees that a section exists and is locked, its user-chosen label, and the number, sizes and timestamps of files. Cannot read the section's real name, page titles, folders, page content or assets. |
| Storage provider | As in version 1, plus can count locked sections, because each has a cleartext `sections/<id>.keys.json`. It cannot tell which page files belong to which section. |
| Someone using a laptop where the section is currently unlocked, or malware running as the user | Not defended. Applications should offer to lock again on quit and after a period of inactivity. |

## Files

```
My Notes.notebook/
  keys.json                          version 2 once any section has been locked
  notebook.nce
  pages/<uuid>.nce                   unchanged: one directory for every scope
  assets/<stem>.nce                  unchanged
  sections/<section-uuid>.keys.json  cleartext, key slots for one locked section
  sections/<section-uuid>.nce        encrypted section manifest (kind 4)
```

Pages and assets stay in the shared `pages/` and `assets/` directories whichever scope they belong to. That keeps the grouping of pages into sections hidden from the provider. Which key opens a file is decided by its header, not by where it is stored (see "Choosing the key").

### Notebook `keys.json`

`version` becomes `2` as soon as the notebook gains its first locked section, and the update must be written before any object of a locked section. It is never lowered. A reader that only understands version 1 meets a higher version and must stop with the message that the notebook needs a newer app, as the version 1 rules already require. This is what stops an old app from saving a manifest that drops the lock.

Readers of this version accept `keys.json` versions 1 and 2.

### Placeholder in the notebook manifest

A locked section appears in `notebook.json` only as

```json
{ "id": "cccccccc-0000-4000-8000-000000000001", "name": "Locked section", "locked": true }
```

`id` is the section's id for good. `name` is a label the user chose, shown while the section is locked, default `Locked section`. It is not the real name. There is no `items` key. An unlocked section has no `locked` key. The order of sections in the sidebar is the order in `notebook.json`.

### `sections/<section-uuid>.keys.json`

```json
{
  "format": "notecanvas-locked-section",
  "version": 2,
  "notebookId": "00112233-4455-6677-8899-aabbccddeeff",
  "sectionId": "cccccccc-0000-4000-8000-000000000001",
  "slots": [ { "type": "passphrase", ... }, { "type": "recovery", ... } ]
}
```

The slot objects have the same fields as in version 1. Differences:

- The wrapped key is the **Section Key**, 32 random bytes made when the section is locked.
- Slot associated data: the ASCII bytes `notecanvas/v2/section-keyslot`, then the 16 bytes of `notebookId`, the 16 bytes of `sectionId`, and the 16 bytes of the slot `id`.
- Passphrase KEK: unchanged (PBKDF2-HMAC-SHA-256 over the NFKC passphrase, slot salt and iteration count). The version 1 limits on iteration count and the 12 character minimum apply.
- Recovery KEK: HKDF-SHA-256 with input key material the 32 byte recovery key, salt the 32 bytes `notebookId` followed by `sectionId`, info the ASCII bytes `notecanvas/v2/section-recovery-kek`, 32 bytes out.
- Recovery display form: as in version 1, but the check value uses the prefix `notecanvas/v2/section-recovery-check`. A section recovery key is therefore rejected as a notebook recovery key, and the reverse, as a typing mistake.

### Section object envelope

Same 35 byte header as version 1, with these values:

| Field | Value |
|---|---|
| Magic | `NCE1` |
| Format version | `2`, meaning "encrypted under a Section Key" |
| Flags | `0` |
| Kind | `2` page, `3` asset, `4` section manifest |

Encryption:

1. Object key = HKDF-SHA-256 with input key material the Section Key, salt the object salt, info the ASCII bytes `notecanvas/v2/section-object`, 32 bytes out.
2. Associated data = the 35 header bytes, then the 16 bytes of `notebookId`, then the 16 bytes of `sectionId`, then the UTF-8 logical path.
3. AES-256-GCM as in version 1, with a fresh random salt and nonce on every write.

Binding `sectionId` means a page cannot be moved from one locked section to another, or served as part of the wrong section. The different info string and the different version byte keep the two key domains apart.

### Section manifest

Logical path `sections/<lowercase-uuid>.json`, stored path `sections/<lowercase-uuid>.nce`, kind `4`. The plaintext is the JSON of the section as `notebook.json` would hold it if the section were not locked: `id`, `name` and `items` (and the legacy `pages` list), plus the integer `revision`, absent while 0 and increased by one on every write, as for the notebook manifest. The section's real name, its folder tree and its page titles live only here.

## Choosing the key

A reader decides which key opens a file from the header's version byte:

- Version `1`: the Notebook Key, exactly as in version 1.
- Version `2`: the Section Key of the section whose manifest lists that page or asset.

A page or asset belongs to exactly one section: the one that references it. Assets are never shared between sections. Copying or moving a page into another section means re-encrypting it for the destination and copying its assets under new stems.

## Operations

**Lock a section.** The section id does not change.

1. Make the Section Key and a recovery key. Write `sections/<id>.keys.json`.
2. If `keys.json` is still version 1, rewrite it as version 2.
3. Write `sections/<id>.nce` holding the real name and items.
4. Re-encrypt every page and asset of the section under the Section Key, one file at a time, each written to a temporary name and renamed into place.
5. Last, write `notebook.json` with the placeholder in place of the section (revision plus one).
6. Show the recovery key and make the user confirm they saved it, as for a notebook.

**Interrupted lock.** If the app stops after step 1 and before step 5, the notebook manifest still lists the section as unlocked while some or all of its files carry version `2` headers. A reader that meets a version 2 file in a section not marked locked must not treat it as corrupt. It must ask for that section's passphrase (or recovery key) and either finish the lock or roll it back by re-encrypting the section under the Notebook Key and deleting the section files. Without the passphrase those pages stay unreadable.

**Add, edit or delete content in a locked section.** Write the page first, then `sections/<id>.nce` with the revision increased, as the version 1 ordering rule says. The notebook manifest is not touched.

**Change a section passphrase.** Derive a new KEK, wrap the same Section Key into a new slot, replace the old slot in `sections/<id>.keys.json`. Nothing else is rewritten. Changing the notebook passphrase does not affect any section.

**Remove the lock from a section** (requires the section to be unlocked).

1. Re-encrypt every page and asset under the Notebook Key (version 1 headers).
2. Write `notebook.json` with the full section in place of the placeholder.
3. Delete `sections/<id>.nce` and `sections/<id>.keys.json`.

If the app stops after step 1, the section still shows as locked but its files are readable with the Notebook Key alone. The key is chosen from each file's header, so reading still works. The app should offer to finish or to lock it again. After step 2, leftover section files are ignored and may be deleted.

**Encrypt a plain notebook.** Unchanged. A locked section can only be made afterwards.

**Import into a locked section.** An import makes a new section. Lock it afterwards. Importing straight into an existing locked section is not part of this version.

## Applications

These are not part of the format, but compatible clients should:

- Show a padlock and the label, never the real name, while locked, and ask for the passphrase on selecting it.
- Offer to remember a Section Key in the system keychain on that device only.
- Lock again on quit and after idle time, and clear the Section Key and any decrypted page from memory.
- Keep locked content out of anything that could index it, such as a search index or thumbnails, unless the index is stored under the Section Key too.

## Versioning

Format version 2 means "has locked sections". A notebook with no locked section stays at version 1 and stays readable by version 1 clients. Version 2 files, once written, are not downgraded automatically.

## Open questions

1. **Rollback.** As in version 1, an attacker with write access to storage can replace a locked page with an older valid copy of itself. The section manifest could record a hash or revision per page, now that each section has its own manifest to put it in. Decide with the sync design.
2. **Revoking a slot.** As in version 1, removing a slot does not stop someone who already had it. Real revocation means a new Section Key and a re-encryption of that section only, which is cheaper than for a whole notebook.
3. **Recovery key per section.** A separate string to keep for every locked section is a burden. A possible later addition is an opt-in slot type that stores the Section Key under a user-held recovery key shared across several sections. Version 2 does not define it.
4. **Folder locks.** The same mechanism could lock a folder if folders had their own manifests. Not in this version.
5. **Independent review.** As in version 1.

## Test vectors

`encryption-section-vectors.json` holds fixed inputs and outputs for a section passphrase slot, a section recovery slot, a section manifest, a page and an asset, plus one notebook scope page for contrast. It also lists the cases a reader must reject:

- a section object read under another section id
- a section object moved to another logical path
- a section object read as a different notebook
- a flipped ciphertext bit
- a changed kind byte
- a section object opened with the Notebook Key
- a section object read as a notebook scope object
- a notebook scope object read as a section object
- a version byte changed from 2 to 1

An implementation is conformant when it reproduces every value and rejects every case. The keys and passphrases in the file are public and must never be used for real data.
