# google_vs_cf
Compare Cloudflare DNS and Google DNS.

## Features
- Test plain DNS: `1.1.1.1` vs `8.8.8.8`
- Select transport at startup: Plain DNS / DoT / DoH
- Probe encrypted upstream separately
- Force apply DNS and lock `/etc/resolv.conf`
- Purge `systemd-resolved` in locked-file mode
- Reinstall `systemd-resolved` and apply a profile
- Optional DoH helper for `systemd-resolved`
- Unlock and show current status

## Profiles
- CF Dual: `1.1.1.1 -> 1.0.0.1`
- Google Dual: `8.8.8.8 -> 8.8.4.4`
- CF First, Google Fallback: `1.1.1.1 -> 8.8.8.8`
- Google First, CF Fallback: `8.8.8.8 -> 1.1.1.1`

## Transport
- Plain DNS
- DoT
- DoH

## Notes
- DoT is the recommended mode.
- Force mode purges `systemd-resolved` and writes a locked `/etc/resolv.conf`.
- Resolved mode reinstalls `systemd-resolved` and applies the selected profile.
- DoH mode uses a local `cloudflared` helper on `127.0.0.1:5053`.
- If encrypted upstream is unstable, use Force apply + lock.

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

## Menu
1. Test plain DNS
2. Probe selected transport
3. Force apply + lock
4. Reinstall resolved + apply
5. Unlock only
6. Show status
7. Change transport
