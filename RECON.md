# Recon on Lemma — The Bug Hunter's Methodology (Jhaddix) toolchain

This fork bakes the full TBHM recon stack into the Lambda **container image** (10 GB),
so you can run the whole methodology from disposable, rotating-IP Lambda workers.

> Every command below is a Lemma "tool" (a file in `tools/`). Invoke them through
> the web-cli, or via `lemmacli` where you can pipe stdin/stdout between local and
> remote and **fan out** across many Lambdas with `-p` (per-line), `-d` (divided
> stdin) and `-i` (invocation count). Chain phases by piping one tool's output
> into the next.

## Lambda constraints (read once)
- **15 min hard timeout per invocation.** Big bruteforce/scan jobs must be chunked
  with `-p`/`-d` fan-out, or split the input yourself. massdns/dnsx are fast enough
  that puredns over a 100k list finishes well inside the window.
- **Unprivileged, no raw sockets.** No SYN scan / masscan. `naabu` is wrapped to
  default to **connect scan** (`-s c`). `nmap`-style SYN is out.
- **Read-only FS except `/tmp`.** All wrappers set `HOME`/state to `/tmp`.
  `EphemeralStorage` is sized in the SAM template (default 4 GB; up to 10 GB).
- **No screenshots.** gowitness/aquatone need chromium (heavy, fiddly headless on
  Lambda) and are intentionally not bundled.
- **Fan-out + `/tmp` don't mix.** A wordlist fetched with `getwl` lives only on the
  one warm instance. For fan-out, use a **baked** wordlist (`tools/wordlists/*`).

## Tool inventory (baked)
- **Passive subs:** `subfinder`, `amass`, `assetfinder`, `findomain`, `github-subdomains`
- **Cert / ASN / CIDR:** `tlsx`, `asnmap`, `mapcidr`, `cdncheck`
- **Brute / permute / resolve:** `puredns`, `shuffledns`, `massdns`, `dnsx`, `alterx`, `dnsgen`
- **Probe:** `httpx`, `httprobe`
- **Ports:** `naabu` (connect scan)
- **Crawl:** `katana`, `gau`, `waybackurls`, `hakrawler`, `gospider`
- **JS / content:** `subjs`, `ffuf`, `feroxbuster`
- **Params:** `arjun`, `paramspider`, `gf` (+ patterns), `qsreplace`
- **Vuln:** `nuclei` (+ templates), `dalfox`, `smuggler`
- **Utils:** `anew`, `unfurl`, `uro`, `interactsh-client`, `getwl`
- **Wordlists:** curated SecLists subset in `tools/wordlists/`; big assetnote/SecLists
  lists on demand via `getwl` (e.g. `getwl an-best-dns`, `getwl dirlist-big`).

---

## 1. Seed discovery (ASN / CIDR / certs)
```
asnmap -d target.com                       # ASNs for an org
echo 1.2.3.0/24 | mapcidr                   # expand/aggregate CIDRs
tlsx -san -cn -u target.com                 # names from TLS certs
```

## 2. Subdomain enumeration (passive)
```
subfinder -d target.com -all -silent
amass enum -passive -d target.com
assetfinder --subs-only target.com
findomain -t target.com -q
github-subdomains -d target.com -t $GH_TOKEN
```
Merge everything client-side or with `anew`:
```
... | anew subs.txt
```

## 3. Bruteforce + permutations + resolve
```
# DNS bruteforce against a wordlist (baked default, or `getwl an-best-dns`)
puredns bruteforce tools/wordlists/subdomains-top1m-110k.txt target.com

# permutations from known subs, then resolve
cat subs.txt | alterx | puredns resolve
cat subs.txt | dnsgen - | puredns resolve

# plain resolve / probe DNS records
cat subs.txt | dnsx -silent -a -resp
```
`puredns`/`shuffledns` auto-use the baked `massdns` + `config/resolvers.txt`.

## 4. HTTP probing
```
cat resolved.txt | httpx -silent -td -title -sc -ip -cdncheck
cat resolved.txt | httprobe
```

## 5. Port scan (connect)
```
cat resolved.txt | naabu -top-ports 1000 -silent      # -s c is forced by the wrapper
```

## 6. Crawl + historical URLs
```
katana -u https://app.target.com -jc -d 3 -silent
echo target.com | gau --subs
echo target.com | waybackurls
cat live.txt | hakrawler
gospider -S live.txt -c 10 -d 2
```
Dedupe the firehose:
```
cat urls.txt | uro | anew urls.clean.txt
```

## 7. JS recon
```
cat urls.clean.txt | subjs                            # pull .js URLs
cat js.txt | nuclei -t http/exposures -duc            # secrets/exposures (wrapper adds templates)
```

## 8. Parameter discovery
```
arjun -u https://app.target.com/api/x -m GET
paramspider -d target.com
cat urls.clean.txt | gf xss | qsreplace '"><svg onload=1>'
```

## 9. Content discovery
```
ffuf -w tools/wordlists/raft-large-directories.txt -u https://app.target.com/FUZZ -mc all -fc 404
feroxbuster -u https://app.target.com -w tools/wordlists/raft-large-files.txt
# bigger list on a single warm instance:
ffuf -w "$(getwl dirlist-big)" -u https://app.target.com/FUZZ
```

## 10. Vuln scanning
```
cat live.txt | nuclei -severity medium,high,critical          # templates auto-loaded, -duc set
cat params.txt | dalfox pipe
cat live.txt | smuggler                                       # request smuggling probe
```

---

## Fan-out patterns (beat the 15-min wall)
With `lemmacli`, spread a host list across N Lambdas (each gets a slice of stdin):
```
cat resolved.txt | lemmacli -p 'httpx -silent -title -sc'      # per-line across workers
cat hosts.txt    | lemmacli -d 'naabu -top-ports 1000'         # stdin divided across workers
cat targets.txt  | lemmacli -d 'nuclei -severity high,critical'
```
Because each worker is a fresh Lambda with its own egress IP, fan-out also spreads
your source IPs — useful for rate-limited targets. Keep wordlists **baked** so every
worker has them.
