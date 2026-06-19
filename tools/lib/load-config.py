#!/usr/bin/env python3
"""
load-config.py <source> <dest>

Fetch a tool config (e.g. API-key provider config) from AWS and write it to a
path under /tmp at runtime, so secrets never live in the container image.

source schemes:
  ssm:/lemma/subfinder          SSM Parameter Store (SecureString, decrypted)
  secret:lemma/amass            Secrets Manager (name or full ARN)
  s3://bucket/key.yaml          S3 object
  env:SUBFINDER_PROVIDER_YAML   contents of another environment variable

The Lambda execution role must allow reading the chosen source (see API-KEYS.md).
Idempotent: skips if <dest> already exists and is non-empty (warm reuse).
Failures are non-fatal — the tool just runs without keys.
"""
import os
import sys
import pathlib


def fetch(src: str) -> str:
    if src.startswith("env:"):
        return os.environ.get(src[4:], "")

    import boto3  # only imported when an AWS source is used

    if src.startswith("ssm:"):
        name = src[4:]
        return boto3.client("ssm").get_parameter(
            Name=name, WithDecryption=True
        )["Parameter"]["Value"]

    if src.startswith("secret:"):
        name = src[7:]
        return boto3.client("secretsmanager").get_secret_value(
            SecretId=name
        )["SecretString"]

    if src.startswith("s3://"):
        bucket, _, key = src[5:].partition("/")
        return (
            boto3.client("s3")
            .get_object(Bucket=bucket, Key=key)["Body"]
            .read()
            .decode()
        )

    raise ValueError(f"unknown source scheme: {src}")


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: load-config.py <source> <dest|->")
    src, dest_arg = sys.argv[1], sys.argv[2]

    # dest "-" => print the resolved value to stdout (for single secrets like a
    # token); otherwise write to the file path (idempotent per warm instance).
    if dest_arg == "-":
        data = fetch(src)
        if data:
            sys.stdout.write(data.strip())
        return

    dest = pathlib.Path(dest_arg)
    if dest.exists() and dest.stat().st_size > 0:
        return  # already loaded on this warm instance

    data = fetch(src)
    if not data:
        return

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(data)
    dest.chmod(0o600)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never break the recon run over a missing key file
        sys.stderr.write(f"[load-config] {exc}\n")
