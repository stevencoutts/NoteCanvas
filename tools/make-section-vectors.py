#!/usr/bin/env python3
"""Reference implementation of locked sections (docs/encryption-locked-sections.md).

It builds on the version 1 reference in tools/make-vectors.py and produces
docs/encryption-section-vectors.json. All inputs are fixed and public. Never use them for real data.

    pip install cryptography
    python3 tools/make-section-vectors.py > docs/encryption-section-vectors.json
"""
import base64, hashlib, importlib.util, json, os, uuid
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("v1", os.path.join(_here, "make-vectors.py"))
v1 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(v1)

MAGIC = b"NCE1"
VERSION_SECTION = 2
KIND_PAGE, KIND_ASSET, KIND_SECTION = 2, 3, 4
INFO_OBJECT = b"notecanvas/v2/section-object"
INFO_RECOVERY = b"notecanvas/v2/section-recovery-kek"
AAD_SLOT = b"notecanvas/v2/section-keyslot"
CHECK_PREFIX = b"notecanvas/v2/section-recovery-check"


def wrap(kek, nonce, notebook_id, section_id, slot_id, section_key):
    return AESGCM(kek).encrypt(nonce, section_key, AAD_SLOT + notebook_id + section_id + slot_id)


def unwrap(kek, nonce, notebook_id, section_id, slot_id, wrapped):
    return AESGCM(kek).decrypt(nonce, wrapped, AAD_SLOT + notebook_id + section_id + slot_id)


def recovery_kek(recovery_key, notebook_id, section_id):
    return v1.hkdf(recovery_key, notebook_id + section_id, INFO_RECOVERY)


def recovery_display(recovery_key):
    check = hashlib.sha256(CHECK_PREFIX + recovery_key).digest()[:3]
    text = base64.b32encode(recovery_key + check).decode("ascii")
    return "-".join(text[i:i + 4] for i in range(0, len(text), 4))


def recovery_parse(text):
    raw = base64.b32decode(text.replace("-", "").replace(" ", "").upper())
    key, check = raw[:32], raw[32:]
    if hashlib.sha256(CHECK_PREFIX + key).digest()[:3] != check:
        raise ValueError("recovery key checksum mismatch")
    return key


def seal(section_key, notebook_id, section_id, kind, logical_path, plaintext, salt, nonce):
    header = MAGIC + bytes([VERSION_SECTION, 0, kind]) + salt + nonce
    key = v1.hkdf(section_key, salt, INFO_OBJECT)
    aad = header + notebook_id + section_id + logical_path.encode("utf-8")
    return header + AESGCM(key).encrypt(nonce, plaintext, aad)


def open_(section_key, notebook_id, section_id, logical_path, blob):
    header, body = blob[:35], blob[35:]
    if header[:4] != MAGIC or header[4] != VERSION_SECTION or header[5] != 0:
        raise ValueError("unsupported object")
    salt, nonce = header[7:23], header[23:35]
    key = v1.hkdf(section_key, salt, INFO_OBJECT)
    return AESGCM(key).decrypt(nonce, body, header + notebook_id + section_id + logical_path.encode("utf-8"))


def main():
    b64 = v1.b64
    notebook_id = uuid.UUID("00112233-4455-6677-8899-aabbccddeeff").bytes
    notebook_key = bytes(range(0x00, 0x20))             # the version 1 vectors' Notebook Key
    section_id = uuid.UUID("cccccccc-0000-4000-8000-000000000001").bytes
    other_section = uuid.UUID("cccccccc-0000-4000-8000-000000000002").bytes
    section_key = bytes(range(0xc0, 0xe0))
    passphrase = "tangerine violin quietly ascend"
    pass_salt = bytes(range(0x11, 0x21))
    pass_slot = uuid.UUID("a0a0a0a0-0000-4000-8000-000000000011").bytes
    rec_slot = uuid.UUID("a0a0a0a0-0000-4000-8000-000000000012").bytes
    recovery_key = bytes(range(0x01, 0x21))
    kdf = dict(alg="pbkdf2-hmac-sha256", iterations=600000)

    kek = v1.passphrase_kek(passphrase, pass_salt, kdf["iterations"])
    pass_nonce = bytes(range(0x21, 0x2d))
    pass_wrapped = wrap(kek, pass_nonce, notebook_id, section_id, pass_slot, section_key)
    assert unwrap(kek, pass_nonce, notebook_id, section_id, pass_slot, pass_wrapped) == section_key

    rkek = recovery_kek(recovery_key, notebook_id, section_id)
    rec_nonce = bytes(range(0x31, 0x3d))
    rec_wrapped = wrap(rkek, rec_nonce, notebook_id, section_id, rec_slot, section_key)
    assert unwrap(rkek, rec_nonce, notebook_id, section_id, rec_slot, rec_wrapped) == section_key
    shown = recovery_display(recovery_key)
    assert recovery_parse(shown.lower()) == recovery_key

    sid = str(uuid.UUID(bytes=section_id))
    manifest_path = f"sections/{sid}.json"
    manifest_plain = ('{"id":"%s","name":"Customers","revision":1,"items":[{"page":{"_0":{"id":"aaaaaaaa-0000-4000-8000-000000000011",'
                      '"title":"Test"}}}]}' % sid).encode()
    manifest_blob = seal(section_key, notebook_id, section_id, KIND_SECTION, manifest_path, manifest_plain,
                         bytes(range(0x41, 0x51)), bytes(range(0x51, 0x5d)))
    assert open_(section_key, notebook_id, section_id, manifest_path, manifest_blob) == manifest_plain

    page_path = "pages/aaaaaaaa-0000-4000-8000-000000000011.json"
    page_plain = b'{"id":"aaaaaaaa-0000-4000-8000-000000000011","title":"Test","objects":[]}'
    page_blob = seal(section_key, notebook_id, section_id, KIND_PAGE, page_path, page_plain,
                     bytes(range(0x61, 0x71)), bytes(range(0x71, 0x7d)))
    assert open_(section_key, notebook_id, section_id, page_path, page_blob) == page_plain

    asset_path = "assets/bbbbbbbb-0000-4000-8000-000000000011.png"
    asset_plain = bytes(range(255, -1, -1))
    asset_blob = seal(section_key, notebook_id, section_id, KIND_ASSET, asset_path, asset_plain,
                      bytes(range(0x81, 0x91)), bytes(range(0x91, 0x9d)))
    assert open_(section_key, notebook_id, section_id, asset_path, asset_blob) == asset_plain

    # A notebook scope (version 1) page made with the Notebook Key, to prove the two scopes cannot be confused.
    v1_page_blob = v1.seal(notebook_key, notebook_id, v1.KIND_PAGE, page_path, page_plain,
                           bytes(range(0xa1, 0xb1)), bytes(range(0xb1, 0xbd)))

    rejects = []

    def must_reject(label, fn):
        try:
            fn()
        except Exception:
            rejects.append(label)
        else:
            raise SystemExit("must reject: " + label)

    must_reject("section object read under another section id",
                lambda: open_(section_key, notebook_id, other_section, page_path, page_blob))
    must_reject("section object moved to another logical path",
                lambda: open_(section_key, notebook_id, section_id, "pages/aaaaaaaa-0000-4000-8000-000000000012.json", page_blob))
    must_reject("section object read as a different notebook",
                lambda: open_(section_key, bytes(16), section_id, page_path, page_blob))
    must_reject("flipped ciphertext bit",
                lambda: open_(section_key, notebook_id, section_id, page_path, page_blob[:-1] + bytes([page_blob[-1] ^ 1])))
    must_reject("flipped header kind",
                lambda: open_(section_key, notebook_id, section_id, page_path, page_blob[:6] + bytes([KIND_ASSET]) + page_blob[7:]))
    must_reject("section object opened with the Notebook Key",
                lambda: open_(notebook_key, notebook_id, section_id, page_path, page_blob))
    must_reject("section object read as a notebook scope object",
                lambda: v1.open_(notebook_key, notebook_id, page_path, page_blob))
    must_reject("notebook scope object read as a section object",
                lambda: open_(section_key, notebook_id, section_id, page_path, v1_page_blob))
    must_reject("version byte changed from 2 to 1",
                lambda: v1.open_(section_key, notebook_id, page_path, page_blob[:4] + bytes([1]) + page_blob[5:]))

    out = {
        "note": "Public test vectors for locked sections. Every key here is published and must never protect real data.",
        "format": "notecanvas-locked-section", "version": 2,
        "notebookId": str(uuid.UUID(bytes=notebook_id)),
        "notebookKeyHex": notebook_key.hex(),
        "sectionId": sid,
        "otherSectionId": str(uuid.UUID(bytes=other_section)),
        "sectionKeyHex": section_key.hex(),
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
            {"kind": "section", "logicalPath": manifest_path, "plaintextUtf8": manifest_plain.decode(), "objectHex": manifest_blob.hex()},
            {"kind": "page", "logicalPath": page_path, "plaintextUtf8": page_plain.decode(), "objectHex": page_blob.hex()},
            {"kind": "asset", "logicalPath": asset_path, "plaintextHex": asset_plain.hex(), "objectHex": asset_blob.hex()},
        ],
        "notebookScopePage": {"logicalPath": page_path, "objectHex": v1_page_blob.hex()},
        "mustReject": rejects,
    }

    # Second pass: rebuild everything from the published JSON alone, as another implementation would.
    check = json.loads(json.dumps(out))
    nid = uuid.UUID(check["notebookId"]).bytes
    sec = uuid.UUID(check["sectionId"]).bytes
    ps = check["passphraseSlot"]
    k = v1.passphrase_kek(ps["passphrase"], base64.b64decode(ps["kdf"]["salt"]), ps["kdf"]["iterations"])
    key_from_passphrase = unwrap(k, base64.b64decode(ps["nonce"]), nid, sec, uuid.UUID(ps["slotId"]).bytes,
                                 base64.b64decode(ps["wrappedKey"]))
    rs = check["recoverySlot"]
    rk = recovery_kek(recovery_parse(rs["display"]), nid, sec)
    key_from_recovery = unwrap(rk, base64.b64decode(rs["nonce"]), nid, sec, uuid.UUID(rs["slotId"]).bytes,
                               base64.b64decode(rs["wrappedKey"]))
    assert key_from_passphrase == key_from_recovery == bytes.fromhex(check["sectionKeyHex"])
    for o in check["objects"]:
        plain = open_(key_from_passphrase, nid, sec, o["logicalPath"], bytes.fromhex(o["objectHex"]))
        expected = bytes.fromhex(o["plaintextHex"]) if "plaintextHex" in o else o["plaintextUtf8"].encode()
        assert plain == expected

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
