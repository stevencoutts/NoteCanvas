#!/usr/bin/env python3
"""Reference implementation of the NoteCanvas encrypted notebook format (docs/encryption-spec.md).

It exists to produce test vectors for other implementations and to prove the spec can be implemented
from the document alone. All inputs below are fixed and public. Never use them for a real notebook.

    pip install cryptography
    python3 tools/make-vectors.py > docs/encryption-vectors.json
"""
import base64, hashlib, json, unicodedata, uuid
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAGIC = b"NCE1"
VERSION = 1
KIND_MANIFEST, KIND_PAGE, KIND_ASSET = 1, 2, 3
INFO_OBJECT = b"notecanvas/v1/object"
INFO_RECOVERY = b"notecanvas/v1/recovery-kek"
AAD_SLOT = b"notecanvas/v1/keyslot"
CHECK_PREFIX = b"notecanvas/v1/recovery-check"


def hkdf(ikm: bytes, salt: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info).derive(ikm)


def passphrase_kek(passphrase: str, salt: bytes, iterations: int) -> bytes:
    secret = unicodedata.normalize("NFKC", passphrase).encode("utf-8")
    return PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=iterations).derive(secret)


def wrap_key(kek: bytes, nonce: bytes, notebook_id: bytes, slot_id: bytes, notebook_key: bytes) -> bytes:
    return AESGCM(kek).encrypt(nonce, notebook_key, AAD_SLOT + notebook_id + slot_id)


def unwrap_key(kek: bytes, nonce: bytes, notebook_id: bytes, slot_id: bytes, wrapped: bytes) -> bytes:
    return AESGCM(kek).decrypt(nonce, wrapped, AAD_SLOT + notebook_id + slot_id)


def recovery_kek(recovery_key: bytes, notebook_id: bytes) -> bytes:
    return hkdf(recovery_key, notebook_id, INFO_RECOVERY)


def recovery_display(recovery_key: bytes) -> str:
    check = hashlib.sha256(CHECK_PREFIX + recovery_key).digest()[:3]
    text = base64.b32encode(recovery_key + check).decode("ascii")  # 35 bytes -> 56 characters, no padding
    return "-".join(text[i:i + 4] for i in range(0, len(text), 4))


def recovery_parse(text: str) -> bytes:
    raw = base64.b32decode(text.replace("-", "").replace(" ", "").upper())
    key, check = raw[:32], raw[32:]
    if hashlib.sha256(CHECK_PREFIX + key).digest()[:3] != check:
        raise ValueError("recovery key checksum mismatch")
    return key


def seal(notebook_key: bytes, notebook_id: bytes, kind: int, logical_path: str,
         plaintext: bytes, salt: bytes, nonce: bytes) -> bytes:
    header = MAGIC + bytes([VERSION, 0, kind]) + salt + nonce
    key = hkdf(notebook_key, salt, INFO_OBJECT)
    aad = header + notebook_id + logical_path.encode("utf-8")
    return header + AESGCM(key).encrypt(nonce, plaintext, aad)


def open_(notebook_key: bytes, notebook_id: bytes, logical_path: str, blob: bytes) -> bytes:
    header, body = blob[:35], blob[35:]
    if header[:4] != MAGIC or header[4] != VERSION or header[5] != 0:
        raise ValueError("unsupported object")
    salt, nonce = header[7:23], header[23:35]
    key = hkdf(notebook_key, salt, INFO_OBJECT)
    return AESGCM(key).decrypt(nonce, body, header + notebook_id + logical_path.encode("utf-8"))


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def main() -> None:
    notebook_id = uuid.UUID("00112233-4455-6677-8899-aabbccddeeff").bytes
    notebook_key = bytes(range(0x00, 0x20))
    passphrase = "correct horse battery staple"
    pass_salt = bytes(range(0x10, 0x20))
    pass_slot = uuid.UUID("a0a0a0a0-0000-4000-8000-000000000001").bytes
    rec_slot = uuid.UUID("a0a0a0a0-0000-4000-8000-000000000002").bytes
    recovery_key = bytes(range(0x40, 0x60))
    kdf = dict(alg="pbkdf2-hmac-sha256", iterations=600000)

    kek = passphrase_kek(passphrase, pass_salt, kdf["iterations"])
    pass_nonce = bytes(range(0x20, 0x2c))
    pass_wrapped = wrap_key(kek, pass_nonce, notebook_id, pass_slot, notebook_key)
    assert unwrap_key(kek, pass_nonce, notebook_id, pass_slot, pass_wrapped) == notebook_key

    rkek = recovery_kek(recovery_key, notebook_id)
    rec_nonce = bytes(range(0x30, 0x3c))
    rec_wrapped = wrap_key(rkek, rec_nonce, notebook_id, rec_slot, notebook_key)
    assert unwrap_key(rkek, rec_nonce, notebook_id, rec_slot, rec_wrapped) == notebook_key
    shown = recovery_display(recovery_key)
    assert recovery_parse(shown.lower()) == recovery_key

    page_path = "pages/aaaaaaaa-0000-4000-8000-000000000001.json"
    page_plain = b'{"id":"aaaaaaaa-0000-4000-8000-000000000001","title":"Test","objects":[]}'
    page_blob = seal(notebook_key, notebook_id, KIND_PAGE, page_path, page_plain,
                     bytes(range(0x60, 0x70)), bytes(range(0x70, 0x7c)))
    assert open_(notebook_key, notebook_id, page_path, page_blob) == page_plain

    manifest_plain = b'{"version":1,"name":"Vectors","revision":1,"sections":[]}'
    manifest_blob = seal(notebook_key, notebook_id, KIND_MANIFEST, "notebook.json", manifest_plain,
                         bytes(range(0x80, 0x90)), bytes(range(0x90, 0x9c)))
    assert open_(notebook_key, notebook_id, "notebook.json", manifest_blob) == manifest_plain

    asset_path = "assets/bbbbbbbb-0000-4000-8000-000000000001.png"
    asset_plain = bytes(range(256))
    asset_blob = seal(notebook_key, notebook_id, KIND_ASSET, asset_path, asset_plain,
                      bytes(range(0xa0, 0xb0)), bytes(range(0xb0, 0xbc)))
    assert open_(notebook_key, notebook_id, asset_path, asset_blob) == asset_plain

    # Negative cases every implementation must reject.
    rejects = []
    for label, path, blob in [
        ("object moved to another logical path", "pages/aaaaaaaa-0000-4000-8000-000000000002.json", page_blob),
        ("object read as a different notebook", page_path, page_blob),
        ("flipped ciphertext bit", page_path, page_blob[:-1] + bytes([page_blob[-1] ^ 1])),
        ("flipped header kind", page_path, page_blob[:6] + bytes([KIND_ASSET]) + page_blob[7:]),
    ]:
        nid = bytes(16) if label == "object read as a different notebook" else notebook_id
        try:
            open_(notebook_key, nid, path, blob)
        except Exception:
            rejects.append(label)
        else:
            raise SystemExit("must reject: " + label)

    out = {
        "note": "Public test vectors. Every key here is published and must never protect real data.",
        "format": "notecanvas-encrypted-notebook", "version": 1,
        "notebookId": str(uuid.UUID(bytes=notebook_id)),
        "notebookKeyHex": notebook_key.hex(),
        "passphraseSlot": {
            "slotId": str(uuid.UUID(bytes=pass_slot)), "passphrase": passphrase,
            "kdf": {**kdf, "salt": b64(pass_salt)}, "kekHex": kek.hex(),
            "nonce": b64(pass_nonce), "wrappedKey": b64(pass_wrapped),
        },
        "recoverySlot": {
            "slotId": str(uuid.UUID(bytes=rec_slot)), "recoveryKeyHex": recovery_key.hex(),
            "display": shown, "kekHex": rkek.hex(),
            "nonce": b64(rec_nonce), "wrappedKey": b64(rec_wrapped),
        },
        "objects": [
            {"kind": "page", "logicalPath": page_path, "plaintextUtf8": page_plain.decode(), "objectHex": page_blob.hex()},
            {"kind": "manifest", "logicalPath": "notebook.json", "plaintextUtf8": manifest_plain.decode(), "objectHex": manifest_blob.hex()},
            {"kind": "asset", "logicalPath": asset_path, "plaintextHex": asset_plain.hex(), "objectHex": asset_blob.hex()},
        ],
        "mustReject": rejects,
    }
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
