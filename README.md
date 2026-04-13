# google_vs_cf

A small interactive Bash utility for Debian-based systems that compares **Cloudflare DNS** and **Google Public DNS**, then lets you apply the resolver profile you prefer.

It can:

- benchmark `1.1.1.1` vs `8.8.8.8`
- show current DNS / `resolv.conf` status
- write a fixed `/etc/resolv.conf` and try to lock it with `chattr +i`
- reinstall and configure `systemd-resolved`
- unlock `/etc/resolv.conf` when needed

---

## Features

- interactive terminal menu
- root check before any operation
- 4 built-in DNS profiles
- **20 rounds per domain**
- **round-robin sampling** across domains to reduce hot-cache bias
- **P90** added to the result table
- **0 ms is kept as a count but excluded from scoring**
- aligned menu and cleaner domain layout
- automatic prompt to install missing packages when needed

---

## Supported profiles

- **CF Dual** → `1.1.1.1` then `1.0.0.1`
- **Google Dual** → `8.8.8.8` then `8.8.4.4`
- **CF First** → `1.1.1.1` then `8.8.8.8`
- **Google First** → `8.8.8.8` then `1.1.1.1`

---

## Requirements

- Debian or Debian-like system
- `bash`
- `apt-get`
- **root privileges to run the script**

The script can prompt to install missing tools such as:

- `bind9-dnsutils` or `dnsutils`
- `coreutils`
- `e2fsprogs`
- `gawk`
- `systemd-resolved`

---

## Download

### curl

```bash
curl -fsSL -o google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh
chmod +x google_vs_cf.sh
```

### wget

```bash
wget -O google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh
chmod +x google_vs_cf.sh
```

---

## Run

**Run it from a root shell.**

If you are not root yet:

```bash
su -
```

Then run:

```bash
bash google_vs_cf.sh
```

If you are already in a root shell, just run the command above directly.

---

## Menu

### 1) Test DNS

Compares:

- Cloudflare → `1.1.1.1`
- Google → `8.8.8.8`

The script tests a fixed domain set and prints per-domain and total results.

Shown metrics:

- `Min`
- `Max`
- `Avg`
- `Median`
- `P90`
- `Bad`
- `0ms`

### 2) Force apply + lock

- stops / disables / masks `systemd-resolved`
- writes the selected profile directly into `/etc/resolv.conf`
- tries to apply `chattr +i`

### 3) Reinstall resolved

- reinstalls `systemd-resolved`
- writes a drop-in profile under:

```text
/etc/systemd/resolved.conf.d/99-google-vs-cf.conf
```

- repoints `/etc/resolv.conf` to the resolved-managed file

### 4) Unlock only

Removes the immutable bit from `/etc/resolv.conf` if present.

### 5) Show status

Displays:

- current `/etc/resolv.conf` mode
- immutable lock state
- current file content
- `systemd-resolved` package / enabled / active status
- active drop-in profile content

---

## Test method

This release uses a more stable test model:

- **20 rounds per domain**
- query type: **A**
- `dig` timeout: **2 seconds**
- **round-robin** rotation across domains instead of querying one domain repeatedly in a block

This helps reduce sequential cache bias and makes the comparison fairer.

---

## 0 ms policy

`0 ms` results are **not treated as normal latency samples**.

They are:

- counted
- shown in the table
- **excluded** from `Avg`, `Median`, `P90`, and final score

This behavior is intentional.

---

## Recommendation logic

The script recommends a resolver in this order:

1. lower bad ratio
2. lower median
3. lower p90
4. lower average

A score is also shown for sorting and comparison:

```text
score = median + 0.35*(p90-median) + 0.10*(avg-median) + 25*bad_ratio
```

Lower is better.

---

## Typical workflow

### Benchmark only

```bash
su -
bash google_vs_cf.sh
```

Then choose `Test DNS` and review the result.

### Apply a fixed resolver and lock it

1. run `Test DNS`
2. decide which profile you want
3. choose `Force apply + lock`
4. confirm the write and lock operation

### Return to a resolved-managed setup

1. choose `Reinstall resolved`
2. select the profile
3. confirm the operation

---

## Safety notes

This script changes system DNS behavior.

It may:

- overwrite `/etc/resolv.conf`
- disable / mask `systemd-resolved`
- reinstall `systemd-resolved`
- apply the immutable bit to `/etc/resolv.conf`

Use it only when you understand how your current system manages DNS.

For remote servers, make sure you still have a safe fallback access path before applying changes.

---

## License

This repository currently uses the MIT License.
