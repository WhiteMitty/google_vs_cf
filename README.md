# google_vs_cf

Compare Cloudflare DNS and Google DNS, select the better one and lock it.

## Features

- Test `1.1.1.1` vs `8.8.8.8`
- 12 rounds for steadier results
- Mild recommendation after each test
- Ignore `0 ms` samples in stats and recommendation
- Force-write DNS and lock `/etc/resolv.conf`
- Stop, disable, and mask `systemd-resolved`
- Install or reinstall `systemd-resolved` and apply a DNS profile
- Unlock `/etc/resolv.conf`
- Show current DNS status
- No package install at startup

## DNS Profiles

- CF Dual: `1.1.1.1 -> 1.0.0.1`
- Google Dual: `8.8.8.8 -> 8.8.4.4`
- CF First: `1.1.1.1 -> 8.8.8.8`
- Google First: `8.8.8.8 -> 1.1.1.1`

## How scoring works

- Median has the highest weight
- Average has the second weight
- Bad results add a mild penalty
- `0 ms` is ignored
- Lower score is better

## Safety notes

- The script does not install packages on startup.
- Package installation happens only after you choose an action that needs it.
- Force mode does not purge `systemd-resolved`.
- It stops, disables, and masks it instead.
- Reinstall mode installs or reinstalls `systemd-resolved` and applies the selected profile.

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
6. Exit
