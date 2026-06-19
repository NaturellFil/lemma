# Adding API keys (subfinder / amass / github-subdomains)

More data sources = more subdomains. subfinder and amass query far more providers
when given API keys (VirusTotal, SecurityTrails, Shodan, Censys, GitHub, Chaos,
BinaryEdge, BeVigil, …). github-subdomains needs a GitHub token.

**Keys are never baked into the image.** They're pulled at runtime from AWS into
`/tmp` by `tools/lib/load-config.py`, driven by environment variables on the Lambda.

## Source schemes
Set the env var to one of:

| Scheme | Example | Notes |
|---|---|---|
| `ssm:` | `ssm:/lemma/subfinder` | SSM Parameter Store, **SecureString**, decrypted at read |
| `secret:` | `secret:lemma/amass` | Secrets Manager (name or ARN) |
| `s3://` | `s3://my-bucket/subfinder.yaml` | S3 object (uncomment `S3ReadPolicy` in the template) |
| `env:` | `env:SUBFINDER_PROVIDER_YAML` | contents held in another env var (≤4 KB total env limit) |

The function env vars are wired in the container templates:
`LEMMA_SUBFINDER_CONFIG`, `LEMMA_AMASS_CONFIG`, `GITHUB_TOKEN`, `LEMMA_GITHUB_TOKEN`.

The execution role already allows reading `ssm:/lemma/*` and `secret:lemma/*`
(see `Policies:` in `templates/template_*_container.yaml`). Keep your parameter /
secret names under that `lemma/` prefix, or widen the policy.

---

## Recommended: SSM Parameter Store (SecureString)

### 1. subfinder provider-config
Write your provider config (subfinder format) and store it:
```bash
cat > /tmp/subfinder.yaml <<'YAML'
virustotal: ["VT_KEY"]
securitytrails: ["ST_KEY"]
shodan: ["SHODAN_KEY"]
censys: ["CENSYS_ID:CENSYS_SECRET"]
github: ["ghp_xxx", "ghp_yyy"]
chaos: ["CHAOS_KEY"]
YAML

aws ssm put-parameter --name /lemma/subfinder --type SecureString \
    --value file:///tmp/subfinder.yaml --overwrite
```

### 2. amass datasources (v4/v5 format)
```bash
cat > /tmp/amass.yaml <<'YAML'
datasources:
  - name: VirusTotal
    ttl: 4320
    creds:
      account:
        apikey: VT_KEY
  - name: SecurityTrails
    ttl: 4320
    creds:
      account:
        apikey: ST_KEY
YAML

aws ssm put-parameter --name /lemma/amass --type SecureString \
    --value file:///tmp/amass.yaml --overwrite
```

### 3. GitHub token
```bash
aws ssm put-parameter --name /lemma/github-token --type SecureString \
    --value 'ghp_xxxxxxxxxxxx' --overwrite
```

### 4. Point the function at them
Either edit `Environment.Variables` in `template.yaml` before `./build.sh`, or set
them on the deployed function:
```bash
aws lambda update-function-configuration --function-name lemma \
  --environment 'Variables={
     LEMMA_API_KEY=...,LEMMA_TIMEOUT=300,HOME=/tmp,PORT=8000,
     AWS_LWA_INVOKE_MODE=response_stream,
     LEMMA_SUBFINDER_CONFIG=ssm:/lemma/subfinder,
     LEMMA_AMASS_CONFIG=ssm:/lemma/amass,
     LEMMA_GITHUB_TOKEN=ssm:/lemma/github-token}'
```
> GitHub token resolution in the `github-subdomains` wrapper: an explicit `-t`
> arg wins; else `LEMMA_GITHUB_TOKEN` (an `ssm:`/`secret:`/`s3://`/`env:` source,
> resolved at runtime); else `GITHUB_TOKEN` (a literal token). Use
> `LEMMA_GITHUB_TOKEN=ssm:/lemma/github-token` to keep it in SSM.

---

## Quick path: inline env (small configs only)
For a couple of keys you can skip AWS storage:
```bash
# store the yaml in one env var, reference it from another
SUBFINDER_PROVIDER_YAML='virustotal: ["VT_KEY"]'
LEMMA_SUBFINDER_CONFIG='env:SUBFINDER_PROVIDER_YAML'
```
Lambda caps **all** env vars at 4 KB combined, so this only fits small configs.

## How it works at runtime
1. The wrapper (`tools/subfinder`, `tools/amass`) sets `HOME=/tmp`.
2. If `LEMMA_*_CONFIG` is set, `load-config.py` fetches the content and writes it
   to the tool's **default** config path under `/tmp/.config/...` (subfinder:
   `provider-config.yaml`; amass: `datasources.yaml`).
3. The tool auto-discovers that config — no extra flags.
4. It's idempotent per warm instance (skips re-fetch if the file already exists).
   A failed fetch is non-fatal: the tool just runs without keys.
