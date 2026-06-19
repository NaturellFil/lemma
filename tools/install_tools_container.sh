#!/bin/bash
#
# install_tools_container.sh <arch> <tools_dir> <app_dir>
#
# Runs in the FINAL Docker stage. Distributes the Go binaries built in stage 1
# (staged at /opt/gobin), adds Rust/prebuilt tools, python tools, nuclei
# templates, DNS resolvers, gf-patterns and a curated wordlist set — the full
# Bug Hunter's Methodology (Jhaddix) recon stack baked into the Lambda image.
#
# Lemma's command allowlist = files directly in tools/ (NOT tools/bin). So:
#   * DIRECT tools  -> binary copied into tools/<name>
#   * WRAPPED tools -> binary into tools/bin/<name>, wrapper file in tools/<name>
#                      (wrappers are committed: nuclei katana puredns shuffledns
#                       gf naabu ffuf gau + python wrappers)
#   * PYTHON tools  -> pip console script on PATH, thin wrapper in tools/<name>
#
set -euo pipefail

arch="${1:-amd64}"
tools_dir="${2:-/var/task/tools}"
app_dir="${3:-/var/task}"
gobin="${GOBIN_SRC:-/opt/gobin}"

# boto3 is needed by tools/lib/load-config.py to pull API-key configs from
# SSM / Secrets Manager / S3 at runtime (see API-KEYS.md).
printf 'boto3\n' > "$app_dir/tool_requirements.txt"

# Rust/prebuilt versions
FEROX_VER=2.13.1
FINDOMAIN_VER=10.0.1
AMASS_VER=5.1.1

echo "[*] Distributing TBHM tools for arch=$arch into $tools_dir"
mkdir -p "$tools_dir/bin" "$tools_dir/wordlists"

dl() { curl -fsSL "$1" -o "$2"; }
tmp() { mktemp -d; }

# ----------------------------------------------------------------------------
# 1) Go binaries from stage 1
# ----------------------------------------------------------------------------
# DIRECT: binary invoked straight from tools/<name>
DIRECT_GO=(
    dnsx httpx tlsx asnmap cdncheck mapcidr alterx interactsh-client
    assetfinder anew unfurl qsreplace httprobe waybackurls hakrawler gospider
    subjs dalfox massdns
)
# WRAPPED: binary into tools/bin, fronted by a committed wrapper in tools/.
# subfinder/github-subdomains are wrapped so they can load API keys at runtime.
WRAPPED_GO=( nuclei katana puredns shuffledns gf naabu ffuf gau subfinder github-subdomains )

for t in "${DIRECT_GO[@]}"; do
    if [ -f "$gobin/$t" ]; then cp -f "$gobin/$t" "$tools_dir/$t"; else echo "[!] missing go bin: $t"; fi
done
for t in "${WRAPPED_GO[@]}"; do
    if [ -f "$gobin/$t" ]; then cp -f "$gobin/$t" "$tools_dir/bin/$t"; else echo "[!] missing go bin: $t"; fi
done

# ----------------------------------------------------------------------------
# 2) Rust / other prebuilt tools
# ----------------------------------------------------------------------------
# feroxbuster (content discovery) — zip assets for both arches
echo "[*] feroxbuster v$FEROX_VER"
t=$(tmp)
if [ "$arch" == "amd64" ]; then
    dl "https://github.com/epi052/feroxbuster/releases/download/v${FEROX_VER}/x86_64-linux-feroxbuster.zip" "$t/ferox.zip"
else
    dl "https://github.com/epi052/feroxbuster/releases/download/v${FEROX_VER}/aarch64-linux-feroxbuster.zip" "$t/ferox.zip"
fi
unzip -o -q "$t/ferox.zip" -d "$t" && mv "$t/feroxbuster" "$tools_dir/feroxbuster" && chmod +x "$tools_dir/feroxbuster"

# findomain (subdomain enum)
echo "[*] findomain v$FINDOMAIN_VER"
t=$(tmp)
if [ "$arch" == "amd64" ]; then
    dl "https://github.com/Findomain/Findomain/releases/download/${FINDOMAIN_VER}/findomain-linux.zip" "$t/fd.zip"
else
    dl "https://github.com/Findomain/Findomain/releases/download/${FINDOMAIN_VER}/findomain-aarch64.zip" "$t/fd.zip"
fi
unzip -o -q "$t/fd.zip" -d "$t" && mv "$t/findomain" "$tools_dir/findomain" && chmod +x "$tools_dir/findomain"

# amass (OWASP) — prebuilt to avoid a heavy compile (v5 ships tar.gz)
echo "[*] amass v$AMASS_VER"
t=$(tmp)
if [ "$arch" == "amd64" ]; then
    dl "https://github.com/owasp-amass/amass/releases/download/v${AMASS_VER}/amass_linux_amd64.tar.gz" "$t/amass.tgz"
else
    dl "https://github.com/owasp-amass/amass/releases/download/v${AMASS_VER}/amass_linux_arm64.tar.gz" "$t/amass.tgz"
fi
tar -xzf "$t/amass.tgz" -C "$t"
# amass is wrapped (runtime API-key loading) -> binary into bin/
mv "$(find "$t" -name amass -type f | head -1)" "$tools_dir/bin/amass" && chmod +x "$tools_dir/bin/amass"

# ----------------------------------------------------------------------------
# 3) Python tools (arjun/dnsgen/uro/paramspider) are pip-installed in the FINAL
#    image stage (Dockerfile.lambda), since their console scripts must land in
#    the runtime python environment. The wrappers are committed in tools/.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 4) nuclei-templates are NOT baked (saves ~250 MB). The nuclei wrapper
#    downloads them to /tmp/nuclei-templates on first use per warm instance.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 5) gf patterns (for grep-of-interest) -> consumed via GF_PATH (set in Dockerfile)
# ----------------------------------------------------------------------------
echo "[*] gf-patterns"
mkdir -p "$tools_dir/gf-patterns"
git clone --depth 1 https://github.com/tomnomnom/gf /tmp/gf_src > /dev/null 2>&1 \
    && cp -f /tmp/gf_src/examples/*.json "$tools_dir/gf-patterns/" 2>/dev/null || true
git clone --depth 1 https://github.com/1ndianl33t/Gf-Patterns /tmp/gfp > /dev/null 2>&1 \
    && cp -f /tmp/gfp/*.json "$tools_dir/gf-patterns/" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 6) DNS resolvers (for puredns / shuffledns / dnsx) -> tools/resolvers.txt
# ----------------------------------------------------------------------------
echo "[*] resolvers"
mkdir -p "$tools_dir/config"
dl "https://raw.githubusercontent.com/trickest/resolvers/main/resolvers.txt" "$tools_dir/config/resolvers.txt" \
    || echo "[!] failed to fetch resolvers (puredns/shuffledns will need -r)"

# ----------------------------------------------------------------------------
# 7) smuggler (HTTP request smuggling probe)
# ----------------------------------------------------------------------------
echo "[*] smuggler"
git clone --depth 1 https://github.com/defparam/smuggler "$tools_dir/bin/smuggler" > /dev/null 2>&1
rm -rf "$tools_dir/bin/smuggler/.git"

# ----------------------------------------------------------------------------
# 8) curated wordlists (baked so they exist on EVERY fan-out worker)
# ----------------------------------------------------------------------------
echo "[*] wordlists (curated SecLists + assetnote subset)"
SL=https://raw.githubusercontent.com/danielmiessler/SecLists/master
declare -A WL=(
  ["common.txt"]="$SL/Discovery/Web-Content/common.txt"
  ["raft-large-directories.txt"]="$SL/Discovery/Web-Content/raft-large-directories.txt"
  ["raft-large-files.txt"]="$SL/Discovery/Web-Content/raft-large-files.txt"
  ["raft-large-words.txt"]="$SL/Discovery/Web-Content/raft-large-words.txt"
  ["directory-list-2.3-medium.txt"]="$SL/Discovery/Web-Content/DirBuster-2007_directory-list-2.3-medium.txt"
  ["api-endpoints.txt"]="$SL/Discovery/Web-Content/api/api-endpoints.txt"
  ["burp-parameter-names.txt"]="$SL/Discovery/Web-Content/burp-parameter-names.txt"
  ["subdomains-top1m-110k.txt"]="$SL/Discovery/DNS/subdomains-top1million-110000.txt"
)
# Big DNS-brute / content lists (assetnote, commonspeak2, all.txt) are pulled on
# demand via `getwl` from the assetnote CDN rather than baked, to keep the image
# lean. See tools/getwl.
for name in "${!WL[@]}"; do
    dl "${WL[$name]}" "$tools_dir/wordlists/$name" || echo "[!] failed: $name (skipping)"
done

chmod +x "$tools_dir"/bin/* "$tools_dir"/* 2>/dev/null || true
echo "[*] Tool install complete. Sizes:"
du -sh "$tools_dir"/* 2>/dev/null | sort -h || true
