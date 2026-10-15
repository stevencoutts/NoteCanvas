# NoteCanvas encrypted notebook format, version 1

Status: **draft for review**. Nothing here is implemented yet. The format is meant to be stable enough that other people can write clients (Windows, mobile, command line) from this document alone. Reference test vectors are in `encryption-vectors.json`, produced by `tools/make-vectors.py`.

## Goals

- A notebook folder can be copied to any storage (iCloud Drive, Dropbox, OneDrive, S3, WebDAV, a USB stick) and the storage provider learns the minimum possible.
- Any platform can implement the format with standard, widely reviewed primitives. No custom cryptography.
- Changing the passphrase does not re-encrypt the notebook.
- A forgotten passphrase is recoverable only through a recovery key. There is no back door.

## Non-goals for version 1

- Sharing a notebook between different people. Version 1 is one person, many devices.
- Hiding the number, size or modification time of files.
- Defending against an attacker who controls the running app or an unlocked device.
- Merging concurrent edits. Sync is a separate document. This format only has to stay merge friendly (see "Constraints for sync").

## Threat model

| Attacker | Outcome |
|---|---|
| Storage provider or anyone who can read the stored files | Sees file count, approximate sizes and timestamps. Cannot read titles, text, images or the section and folder structure. |
| Anyone who can modify stored files | Cannot read or change content undetected. Can delete files, or roll one file back to an older valid copy (see "Open questions"). |
| Someone with a stolen, locked laptop | Cannot read the notebook without the passphrase or recovery key, subject to the strength of the passphrase. |
| Someone with a stolen, unlocked device or malware running as the user | Not defended. |

## Primitives

| Purpose | Choice |
|---|---|
| Authenticated encryption | AES-256-GCM, 96-bit nonce, 128-bit tag |
| Key derivation from a passphrase | PBKDF2-HMAC-SHA-256 (RFC 8018) |
| Key derivation from random keys | HKDF-SHA-256 (RFC 5869) |
| Hashing | SHA-256 |

All multi-byte structure is byte strings. Text is UTF-8. UUIDs are used as their 16 raw bytes in cryptographic inputs and as lowercase hyphenated text in JSON.

The PBKDF2 iteration count is stored beside the slot that uses it, so it can be raised later. The default for new notebooks is 600000 iterations with a 16 byte salt and 32 byte output, the figure OWASP gives for PBKDF2-HMAC-SHA-256. Readers must refuse fewer than 100000 iterations (too weak to trust) and more than 10000000 (to avoid hanging on a hostile file).

PBKDF2 needs almost no memory, so a graphics card can try passphrases much faster than against a memory-hard function such as Argon2id. The format makes up for this in two ways: applications must warn about short passphrases and should offer to generate a long random one, and the `kdf.alg` field lets a later version add `argon2id` as a new slot type without changing anything else. Readers skip slots whose `alg` they do not know.

Passphrases are normalised with Unicode NFKC before being encoded as UTF-8. Applications should require at least 12 characters and recommend a random multi-word passphrase.

## Key hierarchy

```
passphrase ──PBKDF2───► passphrase KEK ─┐
                                          ├─ unwrap ─► Notebook Key (32 random bytes)
recovery key ──HKDF────► recovery KEK  ───┘                     │
                                                    HKDF per object
                                                                 ▼
                                                        object key (one per saved object)
```

- The **Notebook Key** is 32 random bytes made once when the notebook is created. It never changes in version 1 and is never stored unwrapped in the notebook folder.
- A **key slot** is one wrapped copy of the Notebook Key. A notebook has at least a passphrase slot and a recovery slot. More slots can be added later (for example a second passphrase).
- Applications may cache the Notebook Key in the operating system keychain so the user is not asked every time. That cache is not part of this format.

## Files in a notebook folder

```
My Notes.notebook/
  keys.json                          cleartext, key slots only
  notebook.nce                       encrypted manifest
  pages/<uuid>.nce                   one encrypted page
  assets/<stem>.nce                  one encrypted asset
```

An unencrypted notebook (today's layout, with `notebook.json` and `pages/<uuid>.json`) is a different format. A folder containing `keys.json` is an encrypted notebook. Implementations must never write plaintext pages into an encrypted notebook.

### Logical paths and stored paths

Every encrypted object has a **logical path**, the name it would have in an unencrypted notebook. The logical path is bound into the encryption (see "Object envelope"), so an object cannot be moved to another name.

| Object | Logical path | Stored path |
|---|---|---|
| Manifest | `notebook.json` | `notebook.nce` |
| Page | `pages/<uuid>.json` | `pages/<uuid>.nce` |
| Asset | `assets/<name>` for example `assets/<uuid>.png` | `assets/<stem>.nce`, where the stem is the name without its extension |

The extension of an asset is dropped from the stored path so the provider cannot tell an image from a PDF by name. It stays part of the logical path, which readers get from the page that references the asset. Asset stems must be unique within a notebook (they are fresh UUIDs, so this holds).

### `keys.json`

```json
{
  "format": "notecanvas-encrypted-notebook",
  "version": 1,
  "notebookId": "00112233-4455-6677-8899-aabbccddeeff",
  "slots": [
    {
      "type": "passphrase",
      "id": "a0a0a0a0-0000-4000-8000-000000000001",
      "kdf": { "alg": "pbkdf2-hmac-sha256", "iterations": 600000, "salt": "<base64, 16 bytes>" },
      "nonce": "<base64, 12 bytes>",
      "wrappedKey": "<base64, 48 bytes>"
    },
    {
      "type": "recovery",
      "id": "a0a0a0a0-0000-4000-8000-000000000002",
      "nonce": "<base64, 12 bytes>",
      "wrappedKey": "<base64, 48 bytes>"
    }
  ]
}
```

- `notebookId` is a random UUID made at creation. It is bound into every encryption so objects cannot be swapped between notebooks.
- Base64 is standard base64 with padding.
- `wrappedKey` is AES-256-GCM ciphertext (32 bytes) followed by the tag (16 bytes) of the Notebook Key.
- Wrapping uses the slot's KEK, a fresh random 12 byte nonce, and this associated data: the ASCII bytes `notecanvas/v1/keyslot`, then the 16 bytes of `notebookId`, then the 16 bytes of the slot `id`.
- Passphrase KEK: PBKDF2-HMAC-SHA-256 over the normalised passphrase using the slot's salt and iteration count, 32 bytes out.
- Recovery KEK: HKDF-SHA-256 with input key material the 32 byte recovery key, salt the 16 bytes of `notebookId`, info the ASCII bytes `notecanvas/v1/recovery-kek`, 32 bytes out.
- Readers try each slot of the right type and stop at the first that unwraps. A slot that fails authentication is skipped, not fatal.
- `keys.json` is not itself authenticated. Deleting a slot only causes a denial of service. A forged slot cannot unwrap to the real key.

### Recovery key

The recovery key is 32 random bytes shown to the user once, at creation. Display form: Base32 (RFC 4648 alphabet, no padding) of the 32 key bytes followed by a 3 byte check value, which is the first 3 bytes of SHA-256 over the ASCII bytes `notecanvas/v1/recovery-check` followed by the key. That is 35 bytes, which is exactly 56 characters, written in groups of four separated by hyphens. Readers ignore hyphens and spaces and accept lower case, and must reject a wrong check value as a typing mistake.

## Object envelope

Every `.nce` file has this exact layout:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Magic, the ASCII bytes `NCE1` |
| 4 | 1 | Format version, `1` |
| 5 | 1 | Flags, `0`. Readers must reject any other value. |
| 6 | 1 | Kind: `1` manifest, `2` page, `3` asset |
| 7 | 16 | Object salt, random for every write |
| 23 | 12 | Nonce, random for every write |
| 35 | n + 16 | Ciphertext followed by the 16 byte tag |

Encryption:

1. Object key = HKDF-SHA-256 with input key material the Notebook Key, salt the object salt, info the ASCII bytes `notecanvas/v1/object`, 32 bytes out.
2. Associated data = bytes 0 to 34 of the file (the whole header), then the 16 bytes of `notebookId`, then the UTF-8 bytes of the logical path.
3. Ciphertext and tag = AES-256-GCM of the plaintext under the object key, the nonce, and that associated data.

Every write draws a fresh salt and nonce. Because each write has its own derived key, random nonces carry no practical collision risk however often a page is saved.

Plaintext by kind:

- Manifest and page: the same JSON the unencrypted format stores. The manifest gains an integer field `revision`, increased by one on every write.
- Asset: the raw file bytes.

Readers must fail the whole read on any authentication failure and must never show partial plaintext.

## Writing

The ordering rules of the current format still apply: write the page file before the manifest that refers to it, and write each file to a temporary name then rename it over the target, so a failure never leaves the manifest pointing at nothing.

## Operations

- **Create:** make `notebookId`, the Notebook Key and the recovery key; write `keys.json`; write an empty manifest. Show the recovery key and make the user confirm they saved it.
- **Unlock:** read `keys.json`, derive the KEK, unwrap the key, then read `notebook.nce`.
- **Change passphrase:** derive a new KEK, wrap the same Notebook Key into a new slot, replace the old slot. Nothing else is rewritten.
- **Add or revoke a slot:** edit `keys.json`. Revoking a slot does not protect data from someone who already had that slot's key, because the Notebook Key is unchanged. See "Open questions".
- **Convert an unencrypted notebook:** encrypt every file into the new layout, write `keys.json` last, verify by reading everything back, and only then offer to remove the plaintext files.

## Versioning

`version` in `keys.json` and in each object header is the format version. A reader that meets a higher version than it supports must stop and say the notebook needs a newer app. It must not try to read it. Additions that older readers can safely ignore do not need a new version.

## Constraints for sync (informative)

Sync is a separate design. This format is written so that it stays possible:

- Each page is its own object, so edits to different pages never conflict.
- The manifest is the only shared file. The plan is to split it into per-section and per-item records before any sync engine is built, so that renaming a section on one device and adding a page on another can merge.
- `revision` lets a client notice that a manifest on the server is older than one it has already seen.

## Open questions

1. **Rollback.** An attacker with write access to storage can replace a page with an older valid copy of itself. The manifest could record a hash or version for each page to catch this, at the cost of rewriting the manifest on every page save. Decide before sync.
2. **Slot revocation.** Removing a device's slot does not stop that device decrypting data it already has. Real revocation needs a new Notebook Key and a full re-encryption. Version 1 documents this and does not solve it.
3. **Compression.** Compressing before encrypting would save space but leaks content length patterns. The flags byte is reserved. Not in version 1.
4. **Padding.** Sizes leak. Padding to fixed steps costs space. Not in version 1.
5. **Cipher.** AES-GCM is chosen because every platform has a hardware backed implementation. XChaCha20-Poly1305 is the alternative if a dependency on libsodium is accepted anyway.
6. **Passphrase guessing resistance.** PBKDF2 was chosen so that every platform, Swift included, can implement the format with no third-party dependency. It is weaker than Argon2id against GPU guessing. The slot format allows adding Argon2id later. Raising the default iteration count over time is expected.
7. **Independent review.** The spec should be reviewed by someone who does applied cryptography before the format is called stable.

## Test vectors

`encryption-vectors.json` holds fixed inputs and outputs for the passphrase slot, the recovery slot, a manifest, a page and an asset, and the cases a reader must reject:

- an object read under a different logical path
- an object read under a different `notebookId`
- a flipped ciphertext bit
- a changed kind byte in the header

An implementation is conformant when it reproduces every value in the file and rejects every listed case. The key and passphrase in the file are public and must never be used for real data.
