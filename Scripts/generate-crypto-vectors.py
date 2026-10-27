#!/usr/bin/env python3
"""Independent M4.2 reference: OpenSSL EVP + Python hashlib/hmac, without CryptoKit.

Writes JSON to stdout; intentionally does not update fixtures. Public test
secrets RFC 7748 only. Run: python3 Scripts/generate-crypto-vectors.py > /tmp/vectors.json
"""
import base64
import ctypes as c
import hashlib
import hmac
import json
import struct
import uuid

lib = c.CDLL('/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib')
P, I, N = c.c_void_p, c.c_int, c.c_size_t


def fn(name, result, args):
    f = getattr(lib, name)
    f.restype, f.argtypes = result, args
    return f


new_key = fn('EVP_PKEY_new_raw_private_key_ex', P, [P, c.c_char_p, P, P, N])
get_public = fn('EVP_PKEY_get_raw_public_key', I, [P, P, c.POINTER(N)])
new_context = fn('EVP_PKEY_CTX_new', P, [P, P])
derive_init = fn('EVP_PKEY_derive_init', I, [P])
set_peer = fn('EVP_PKEY_derive_set_peer', I, [P, P])
derive = fn('EVP_PKEY_derive', I, [P, P, c.POINTER(N)])
free_context = fn('EVP_PKEY_CTX_free', None, [P])
free_key = fn('EVP_PKEY_free', None, [P])
new_cipher = fn('EVP_CIPHER_CTX_new', P, [])
algorithm = fn('EVP_chacha20_poly1305', P, [])
init_cipher = fn('EVP_EncryptInit_ex', I, [P, P, P, P, P])
update = fn('EVP_EncryptUpdate', I, [P, P, c.POINTER(I), P, I])
final = fn('EVP_EncryptFinal_ex', I, [P, P, c.POINTER(I)])
control = fn('EVP_CIPHER_CTX_ctrl', I, [P, I, I, P])
free_cipher = fn('EVP_CIPHER_CTX_free', None, [P])


def x25519(a, b):
    ka = new_key(None, b'X25519', None, a, 32)
    kb = new_key(None, b'X25519', None, b, 32)
    assert ka and kb
    pa, pb, secret = (c.create_string_buffer(32) for _ in range(3))
    count = N(32)
    assert get_public(ka, pa, c.byref(count)) == 1
    assert get_public(kb, pb, c.byref(count)) == 1
    ctx = new_context(ka, None)
    assert derive_init(ctx) == 1 and set_peer(ctx, kb) == 1
    assert derive(ctx, secret, c.byref(count)) == 1
    free_context(ctx)
    free_key(ka)
    free_key(kb)
    return pa.raw, pb.raw, secret.raw


def seal(key, nonce, plaintext, aad):
    ctx = new_cipher()
    out = c.create_string_buffer(len(plaintext) + 16)
    length, tail = I(), I()
    tag = c.create_string_buffer(16)
    assert init_cipher(ctx, algorithm(), None, key, nonce) == 1
    assert update(ctx, None, c.byref(length), aad, len(aad)) == 1
    assert update(ctx, out, c.byref(length), plaintext, len(plaintext)) == 1
    count = length.value
    assert final(ctx, c.byref(out, count), c.byref(tail)) == 1
    assert control(ctx, 0x10, 16, tag) == 1  # EVP_CTRL_AEAD_GET_TAG
    free_cipher(ctx)
    return nonce + out.raw[:count + tail.value] + tag.raw


def mac(key, data):
    return hmac.digest(key, data, 'sha256')


def hkdf(ikm, salt, info):
    return mac(mac(salt, ikm), info + b'\x01')  # Full Extract and Expand, L=32.


def label(s):
    return b'kinrox/v1/' + s.encode('ascii') + b'\0'


def u32(n):
    return struct.pack('>I', n)


def uid(n):
    return uuid.UUID(f'00112233-4455-6677-8899-aabbccddee{n:02x}')


def text(s):
    b = s.encode('utf-8')
    return u32(len(b)) + b


def encode(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def message(n, kind, body):
    return {'v': 1, 'id': str(uid(n)).upper(), 'type': kind, 'body': body}


def b64(b):
    return base64.b64encode(b).decode()


client_private = bytes.fromhex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a')
server_private = bytes.fromhex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb')
client_public, server_public, z = x25519(client_private, server_private)
assert z.hex() == '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'
nonce, token, pin = bytes(range(32)), bytes(range(32, 64)), b'004219'
results = []
for mode in [0, 1]:
    hello = message(1, 'hello', {'minVersion': 1, 'maxVersion': 3,
        'deviceId': str(uid(4)).upper(), 'deviceName': 'iPhone Remote', 'appVersion': '1.0'})
    ack = message(2, 'helloAck', {'version': 1, 'serverId': str(uid(5)).upper(),
        'serverName': 'Mac e\u0301', 'needsPairing': mode == 0,
        'serverPublicKey': b64(server_public), 'nonce': b64(nonce)})
    t = (label('transcript') + bytes([mode]) + u32(1) + uid(1).bytes + u32(1) + u32(3)
        + uid(4).bytes + text('iPhone Remote') + text('1.0') + u32(1) + uid(2).bytes
        + u32(1) + uid(5).bytes + text('Mac e\u0301') + bytes([mode == 0])
        + server_public + nonce + u32(1) + uid(3).bytes + client_public)
    th = hashlib.sha256(t).digest()
    c2s, s2c, confirm = [hkdf(z, nonce, label('key/' + s) + th) for s in ['c2s', 's2c', 'confirm']]
    secret_key = hkdf(pin if mode == 0 else token, confirm,
        label('pin' if mode == 0 else 'auth/server-key') + th)
    cp = mac(secret_key, label('pair/client') + t + uid(6).bytes) if mode == 0 else mac(token, label('auth/client') + t)
    sp = mac(secret_key, (label('pair/server') + t + uid(6).bytes + cp + token)
        if mode == 0 else (label('auth/server') + t + cp))
    key_message = message(3, 'pairRequest' if mode == 0 else 'auth', {'clientPublicKey': b64(client_public)})
    if mode == 1:
        key_message['body'].update(deviceId=str(uid(4)).upper(), proof=b64(cp))
    finish = message(7, 'paired' if mode == 0 else 'authOk', {'serverProof': b64(sp)})
    if mode == 0:
        finish['body']['token'] = b64(token)
    command = message(8, 'requestState', {})
    results.append({'mode': mode, 'hello': hello, 'helloAck': ack, 'keyMessage': key_message,
        'pairProofId': str(uid(6)).upper(), 'finish': finish, 'command': command,
        'clientPrivate': client_private.hex(), 'serverPrivate': server_private.hex(),
        'sharedSecret': z.hex(), 'pin': pin.decode(), 'token': token.hex(), 'transcript': t.hex(),
        'hash': th.hex(), 'c2s': c2s.hex(), 's2c': s2c.hex(), 'confirmation': confirm.hex(),
        'proofKey': secret_key.hex(), 'clientProof': cp.hex(), 'serverProof': sp.hex(),
        'clientFrame': seal(c2s, bytes(12), encode(command), label('frame') + th + b'\0').hex(),
        'serverFrame': seal(s2c, bytes(12), encode(finish), label('frame') + th + b'\1').hex()})
print(json.dumps(results, ensure_ascii=False, indent=2))
