# google_vs_cf

A small interactive Bash utility for Debian-based systems to compare **Cloudflare DNS** and **Google Public DNS**, then apply the preferred resolver profile either as a **locked `/etc/resolv.conf`** or through **`systemd-resolved`**.

Designed for users who want a simple terminal workflow to:

- benchmark `1.1.1.1` vs `8.8.8.8`
- inspect current resolver state
- force a resolver profile into `/etc/resolv.conf` and lock it
- reinstall and configure `systemd-resolved`
- unlock `/etc/resolv.conf` when needed

---

## Highlights

- Interactive terminal menu
- Root privilege check before execution
- DNS comparison between:
  - **Cloudflare**: `1.1.1.1`
  - **Google**: `8.8.8.8`
- Four ready-to-use profiles:
  - `CF Dual` → `1.1.1.1`, `1.0.0.1`
  - `Google Dual` → `8.8.8.8`, `8.8.4.4`
  - `CF First` → `1.1.1.1`, `8.8.8.8`
  - `Google First` → `8.8.8.8`, `1.1.1.1`
- Better-formatted domain display and aligned menu output
- Automatic dependency prompts for test and lock operations
- Resolver state inspection for:
  - `/etc/resolv.conf` mode
  - immutable lock status
  - `systemd-resolved` package / enabled / active state
  - active resolver profile drop-in

---

## DNS Test Method

The script tests the following public resolvers:

- **Cloudflare** → `1.1.1.1`
- **Google** → `8.8.8.8`

It queries a fixed domain set, including:

- `x.com`
- `bbc.com`
- `twitch.tv`
- `intel.com`
- `apple.com`
- `amazon.com`
- `fastly.com`
- `akamai.com`
- `google.com`
- `github.com`
- `youtube.com`
- `netflix.com`
- `telegram.org`
- `bilibili.com`
- `wikipedia.org`
- `microsoft.com`
- `instagram.com`
- `aws.amazon.com`
- `steampowered.com`

### Sampling model

This version uses a **round-robin sampling strategy** across domains.

Instead of querying one domain repeatedly before moving to the next, the script rotates across the domain list in rounds. This reduces hot-cache bias and gives a fairer comparison between resolvers.

### Test count

- **20 rounds per domain**
- query type: **A**
- `dig` timeout per query: **2 seconds**

### 0 ms policy

**`0 ms` results are intentionally preserved as counts but excluded from statistics and recommendation logic.**

That means:

- they are shown in the output
- they are **not** included in `avg`, `median`, `p90`, or final score

This avoids letting cache-granularity artifacts distort the recommendation.

---

## Metrics

For each domain and for the total result, the script shows:

- **Min**
- **Max**
- **Avg**
- **Median**
- **P90**
- **Bad**
- **0ms**

### Meaning of `Bad`

A result is counted as **bad** when the query fails, times out, or does not return a usable `NOERROR` result with a valid numeric query time.

---

## Scoring Model

The current scoring model is:

```text
score = median + 0.35*(p90 - median) + 0.10*(avg - median) + 25*bad_ratio
```

Lower is better.

### Why this model

The script does **not** rank resolvers by average latency alone.
It favors a more stable resolver by prioritizing:

1. **lower bad ratio**
2. **lower median latency**
3. **lower p90 latency**
4. **lower average latency**

This helps avoid choosing a resolver that looks fast on average but is unstable or has worse tail latency.

---

## Menu Functions

### 1) Test DNS
Runs the resolver comparison and prints:

- per-domain results
- total results for each resolver
- summary table
- final recommendation

### 2) Force apply + lock
Disables `systemd-resolved`, writes the selected DNS profile directly into `/etc/resolv.conf`, and then tries to make the file immutable with `chattr +i`.

This is useful when you want a fixed resolver setup that resists automatic overwrite.

### 3) Reinstall resolved + apply
Reinstalls `systemd-resolved`, writes a drop-in config under:

```text
/etc/systemd/resolved.conf.d/99-google-vs-cf.conf
```

and then points `/etc/resolv.conf` to the proper resolved file.

### 4) Unlock only
Removes the immutable flag from `/etc/resolv.conf` if present.

### 5) Show status
Displays:

- current `/etc/resolv.conf` mode
- lock status
- file contents
- `systemd-resolved` status
- active profile file contents

---

## Requirements

- Debian or Debian-like environment with `apt-get`
- Bash
- root privileges

The script can prompt to install missing packages when needed, including tools such as:

- `dnsutils` or `bind9-dnsutils`
- `coreutils`
- `gawk`
- `e2fsprogs`
- `systemd-resolved`

---

## Usage

```bash
sudo bash google_vs_cf_v0.1.1.sh
```

If you keep the original filename:

```bash
sudo bash google_vs_cf.sh
```

---

## Typical Workflow

### Benchmark only

1. Run the script
2. Choose **Test DNS**
3. Review the summary and recommendation
4. Exit without changing the system

### Lock a preferred resolver profile

1. Run **Test DNS**
2. Decide which profile you want
3. Choose **Force apply + lock**
4. Select the DNS profile
5. Confirm the operation

### Return to a `systemd-resolved` setup

1. Choose **Reinstall resolved + apply**
2. Select the profile
3. Confirm the operation

---

## Safety Notes

- The script modifies `/etc/resolv.conf`
- It may **disable, mask, or reinstall** `systemd-resolved`
- It may apply the immutable bit to `/etc/resolv.conf`
- Run it only if you understand how your system currently manages DNS

For remote servers, confirm you have a fallback access path before changing resolver settings.

---

## Design Notes

This release intentionally keeps several practical behaviors:

- **0 ms results remain excluded from scoring**
- **20 rounds per domain** for better sample depth
- **round-robin querying** to reduce sequential cache bias
- **P90** is included to reflect tail behavior
- recommendation is based on **stability first, then latency**

---

## License

Add your preferred license here if you plan to publish the project publicly.

For example:

- MIT
- Apache-2.0
- GPL-3.0

---

## Author

**Doudou Zhang**
