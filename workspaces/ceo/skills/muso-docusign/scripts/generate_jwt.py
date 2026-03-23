#!/usr/bin/env python3
"""Generate a JWT assertion for DocuSign JWT Grant authentication."""
import argparse
import time
import jwt

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--integration-key", required=True)
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--rsa-key-file", required=True)
    parser.add_argument("--auth-server", default="account.docusign.com")
    parser.add_argument("--scopes", default="signature impersonation")
    args = parser.parse_args()

    with open(args.rsa_key_file, "r") as f:
        private_key = f.read()

    now = int(time.time())
    payload = {
        "iss": args.integration_key,
        "sub": args.user_id,
        "aud": args.auth_server,
        "iat": now,
        "exp": now + 3600,
        "scope": args.scopes,
    }

    token = jwt.encode(payload, private_key, algorithm="RS256")
    print(token)

if __name__ == "__main__":
    main()
