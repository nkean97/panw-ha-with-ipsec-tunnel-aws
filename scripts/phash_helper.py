#!/usr/bin/env python3
"""Terraform `external` data-source shim: password on stdin -> $5$ hash on stdout.

Protocol: reads {"password": "..."} as JSON on stdin, writes {"phash": "..."}.
Terraform requires a flat string->string JSON object in both directions.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sha512_crypt import sha256_crypt  # noqa: E402


def main():
    try:
        query = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print("phash_helper: could not parse stdin as JSON: %s" % exc, file=sys.stderr)
        return 1

    password = query.get("password", "")
    if not password:
        print("phash_helper: empty password", file=sys.stderr)
        return 1

    # Deterministic salt derived from the password, so repeated `terraform plan`
    # runs don't produce a new hash every time and show a spurious diff.
    import hashlib

    from sha512_crypt import SALT_CHARS

    # 8 characters, not the 16 the spec permits. SHA-crypt accepts up to 16,
    # but 8 is what every crypt(3) implementation and every PAN-OS-generated
    # hash actually uses, and a device that mishandles a longer salt fails
    # closed -- the config loads, the admin entry is silently unusable, and you
    # get "Invalid Credential" against a hash you can prove is correct.
    seed = hashlib.sha256(("panw-ha-salt:" + password).encode("utf-8")).digest()
    salt = "".join(SALT_CHARS[b % len(SALT_CHARS)] for b in seed[:8])

    json.dump({"phash": sha256_crypt(password, salt)}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
