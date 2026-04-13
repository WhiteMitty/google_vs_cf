# google_vs_cf
Compare Cloudflare DNS and Google DNS.

Version: v 0.1  
Author: Doudou Zhang

## Features
- Fixed test: `1.1.1.1` vs `8.8.8.8`
- Force apply DNS and lock `/etc/resolv.conf`
- Reinstall `systemd-resolved` and apply a DNS profile
- Unlock `/etc/resolv.conf`
- Show current DNS status

## Requirements
- Debian or Ubuntu
- `apt`
- Root privileges

## Start

### curl

```bash
curl -fsSL -o google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh && bash google_vs_cf.sh
```

### wget

```bash
wget -qO google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh && bash google_vs_cf.sh
```

## Menu
1. Test DNS
2. Force apply + lock
3. Reinstall resolved + apply
4. Unlock only
5. Show status

## DNS Profiles
- CF Dual: `1.1.1.1 -> 1.0.0.1`
- Google Dual: `8.8.8.8 -> 8.8.4.4`
- CF First, Google Fallback: `1.1.1.1 -> 8.8.8.8`
- Google First, CF Fallback: `8.8.8.8 -> 1.1.1.1`

## Notes
- Force mode masks and locks `/etc/resolv.conf`.
- Resolved mode writes a drop-in and relinks `/etc/resolv.conf`.
- Unlock first before editing a locked file.
