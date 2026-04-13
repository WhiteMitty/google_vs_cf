# google_vs_cf
Compare Cloudflare DNS and Google DNS.

## Features
- Test `1.1.1.1` vs `8.8.8.8`
- Force apply DNS and lock `/etc/resolv.conf`
- Purge `systemd-resolved` in locked-file mode
- Reinstall `systemd-resolved` and apply a DNS profile
- Unlock `/etc/resolv.conf`
- Show current DNS status

## DNS Profiles
- CF Dual: `1.1.1.1 -> 1.0.0.1`
- Google Dual: `8.8.8.8 -> 8.8.4.4`
- CF First: `1.1.1.1 -> 8.8.8.8`
- Google First: `8.8.8.8 -> 1.1.1.1`

## Menu
1. Test DNS
2. Force apply + lock
3. Reinstall resolved + apply
4. Unlock only
5. Show status

## Notes
- Force mode purges `systemd-resolved`.
- Restore mode reinstalls `systemd-resolved`.
- Locked mode writes `/etc/resolv.conf` directly.
- Restore mode uses `systemd-resolved` with the selected profile.
- To edit `/etc/resolv.conf` manually, unlock it first.

## Requirements
- Debian or Ubuntu
- `apt`
- Root privileges

## Start

### curl

```bash
curl -fsSL -o google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh && sudo bash google_vs_cf.sh
```

### wget

```bash
wget -qO google_vs_cf.sh https://raw.githubusercontent.com/WhiteMitty/google_vs_cf/main/google_vs_cf.sh && sudo bash google_vs_cf.sh
```
