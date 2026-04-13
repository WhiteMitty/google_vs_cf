# google_vs_cf

Compare Cloudflare DNS and Google DNS, select the better one and lock it.

## Features
- Test `1.1.1.1` vs `8.8.8.8`
- More test rounds for steadier results
- Mild recommendation after each test
- Force-write DNS and lock `/etc/resolv.conf`
- Purge `systemd-resolved`
- Reinstall `systemd-resolved` and apply a DNS profile
- Unlock `/etc/resolv.conf`
- Show current DNS status

## DNS Profiles
- CF Dual: `1.1.1.1 -> 1.0.0.1`
- Google Dual: `8.8.8.8 -> 8.8.4.4`
- CF First: `1.1.1.1 -> 8.8.8.8`
- Google First: `8.8.8.8 -> 1.1.1.1`

## How scoring works
The test gives the highest weight to median latency, then average latency.
Bad results add a mild penalty.
Lower score is better.

## Start

### curl

```bash
curl -fsSL -o google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh && sudo bash google_vs_cf.sh
```

### wget

```bash
wget -qO google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh && sudo bash google_vs_cf.sh
```

## Menu
1. Test DNS
2. Force apply + lock
3. Reinstall resolved + apply
4. Unlock only
5. Show status
0. Exit

## Notes
- Force mode purges `systemd-resolved`.
- Reinstall mode installs `systemd-resolved` again.
- Force mode locks `/etc/resolv.conf` with `chattr +i`.
- To edit it manually, unlock it first.
