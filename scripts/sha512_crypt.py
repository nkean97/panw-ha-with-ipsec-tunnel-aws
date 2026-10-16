#!/usr/bin/env python3
"""Pure-Python SHA-crypt ($5$ SHA-256 and $6$ SHA-512) for PAN-OS 'phash'.

Needed because macOS ships LibreSSL (no `openssl passwd -5/-6`) and Python 3.13+
removed the stdlib `crypt` module. Implements Ulrich Drepper's SHA-crypt spec.

phash_helper uses sha256_crypt: $5$ is the format PAN-OS 10.x/11.x itself
emits (`request password-hash`). With a $6$ phash the bootstrap loaded but
every login was rejected with "Invalid Credential".

  python3 sha512_crypt.py 'MyPassword'            # $5$, random salt
  python3 sha512_crypt.py 'MyPassword' saltstring # $5$, fixed salt
  python3 sha512_crypt.py --selftest
"""

import hashlib
import secrets
import sys

B64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
SALT_CHARS = B64[2:]  # avoid '.' and '/' in generated salts

# Byte-shuffle order for the SHA-256 variant, per the spec. The final group
# carries only two bytes and encodes to three characters.
_ORDER_256 = [
    (0, 10, 20), (21, 1, 11), (12, 22, 2), (3, 13, 23), (24, 4, 14),
    (15, 25, 5), (6, 16, 26), (27, 7, 17), (18, 28, 8), (9, 19, 29),
]

# Byte-shuffle order for the SHA-512 variant, per the spec.
_ORDER_512 = [
    (0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4),
    (47, 5, 26), (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51),
    (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13), (56, 14, 35),
    (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19),
    (62, 20, 41),
]


def _b64_encode(digest, order, tail, tail_chars):
    out = []

    def emit(v, n):
        for _ in range(n):
            out.append(B64[v & 0x3F])
            v >>= 6

    for i0, i1, i2 in order:
        emit((digest[i0] << 16) | (digest[i1] << 8) | digest[i2], 4)
    v = 0
    for i in tail:
        v = (v << 8) | digest[i]
    emit(v, tail_chars)
    return "".join(out)


def _repeat_to(block, length):
    return (block * (length // len(block) + 1))[:length]


def sha256_crypt(password, salt=None, rounds=5000):
    """Return a $5$ crypt hash. `rounds` of 5000 omits the rounds= prefix."""
    return _sha_crypt(hashlib.sha256, "5", _ORDER_256, (31, 30), 3,
                      password, salt, rounds)


def sha512_crypt(password, salt=None, rounds=5000):
    """Return a $6$ crypt hash. `rounds` of 5000 omits the rounds= prefix."""
    return _sha_crypt(hashlib.sha512, "6", _ORDER_512, (63,), 2,
                      password, salt, rounds)


def _sha_crypt(h, ident, order, tail, tail_chars, password, salt, rounds):
    if salt is None:
        salt = "".join(secrets.choice(SALT_CHARS) for _ in range(16))
    salt = salt[:16]
    pw = password.encode("utf-8")
    sb = salt.encode("ascii")

    # Digest B: password + salt + password
    b = h(pw + sb + pw).digest()

    # Digest A
    ctx = pw + sb
    ctx += _repeat_to(b, len(pw))
    cnt = len(pw)
    while cnt:
        ctx += b if (cnt & 1) else pw
        cnt >>= 1
    a = h(ctx).digest()

    # Sequences P and S
    dp = h(pw * len(pw)).digest()
    p = _repeat_to(dp, len(pw))
    ds = h(sb * (16 + a[0])).digest()
    s = _repeat_to(ds, len(sb))

    # Stretch
    prev = a
    for i in range(rounds):
        ctx = p if (i % 2) else prev
        if i % 3:
            ctx += s
        if i % 7:
            ctx += p
        ctx += prev if (i % 2) else p
        prev = h(ctx).digest()

    prefix = "$%s$" % ident
    if rounds != 5000:
        prefix += "rounds=%d$" % rounds
    return "%s%s$%s" % (prefix, salt, _b64_encode(prev, order, tail, tail_chars))


_VECTORS = [
    # (fn, password, salt, rounds, expected) — SHA-crypt reference spec values,
    # cross-checked against OpenSSL 3+ `openssl passwd -5/-6`.
    (sha256_crypt, "Hello world!", "saltstring", 5000,
     "$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5"),
    (sha256_crypt, "Hello world!", "saltstringsaltstring", 10000,
     "$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA"),
    (sha256_crypt, "a short string", "asaltof16chars..", 1000,
     "$5$rounds=1000$asaltof16chars..$6sZ0iVeA.5VaYPC6lnLJf8AM4W2hSShAHabqnQKhqmD"),
    (sha512_crypt, "Hello world!", "saltstring", 5000,
     "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI6"
     "8u4OTLiBFdcbYEdFCoEOfaS35inz1"),
    (sha512_crypt, "Hello world!", "saltstringsaltstring", 10000,
     "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbM"
     "CVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."),
    (sha512_crypt, "a short string", "asaltof16chars..", 1000,
     "$6$rounds=1000$asaltof16chars..$rk5zk5.ds1b1IiNEv9FYP3.vld6KmfGD7JtlY/"
     "LdCUSQLhz0267kfFr6WB9IUJJQ0Zy.6XIlEm1bhq.gf4bRe/"),
]


def _selftest():
    ok = True
    for fn, pw, salt, rounds, expected in _VECTORS:
        got = fn(pw, salt, rounds)
        status = "PASS" if got == expected else "FAIL"
        if got != expected:
            ok = False
            print("  expected %s" % expected)
            print("  got      %s" % got)
        print("%s %s rounds=%d salt=%s" % (status, fn.__name__, rounds, salt))
    # Round-trip a random salt to make sure the default path produces a parseable hash.
    h = sha256_crypt("TestPass123")
    assert h.startswith("$5$") and len(h.split("$")) == 4, h
    print("PASS random-salt format: %s" % h)
    return ok


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(0 if _selftest() else 1)
    if len(sys.argv) < 2:
        sys.exit("usage: sha512_crypt.py <password> [salt]")
    print(sha256_crypt(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
