# BackWall — Teejay Edition

**Lightning-fast reverse tunneling manager.**

BackWall is a clean, menu-driven Bash manager for setting up high-performance
reverse tunnels between two servers (typically an **Iran** server and a
**foreign / Kharej** server). It wraps a powerful tunneling core and a friendly
TUI so you can spin up, manage, and monitor tunnels in seconds — no hand-editing
of TOML files required.

> This is a modernised, fully readable rewrite of an earlier Backhaul-based
> script. The logic is unobfuscated, the brand and paths are unified under
> `backwall`, the broken self-updater is fixed, downloads use HTTPS via GitHub
> Releases, and dependency handling now supports apt / dnf / yum / pacman.

---

## Features

- **Interactive menu** — configure, manage, and monitor tunnels with a few keystrokes.
- **Server (Iran) and Client (Kharej) roles** in one script.
- **Many transports:** `tcp`, `tcpmux`, `xtcpmux`, `ws`, `wss`, `wsmux`, `wssmux`, `xwsmux`, `anytls`, `tun`.
- **TUN & IPx** encapsulation with CIDR validation.
- **TLS** with auto-generated self-signed certificates.
- **Mux, tuning, and buffer profiles** for squeezing out performance.
- **Flexible port mapping** — single ports, rewrites (`443=5000`), and ranges (`443-600:5201`).
- **systemd integration** — each tunnel runs as its own auto-restarting service.
- **Self-healing** — recreates missing service files on launch.
- **Self-updating** — pulls the latest script straight from GitHub.

---

## Quick install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GreatTeejay/BackWall/main/install.sh)
```

Then launch it anytime with:

```bash
backwall
```

> Must be run as **root** (it manages systemd services and network interfaces).

---

## Manual install

```bash
git clone https://github.com/GreatTeejay/BackWall.git
cd BackWall
sudo install -m 0755 backwall.sh /usr/local/bin/backwall
sudo backwall
```

---

## Configuration overrides

BackWall reads a few environment variables, so you can point it at your own
fork or mirror without editing the script:

| Variable               | Default                | Purpose                                   |
|------------------------|------------------------|-------------------------------------------|
| `BACKWALL_DIR`         | `/root/backwall-core`  | Install / config directory                |
| `BACKWALL_GH_OWNER`    | `GreatTeejay`          | GitHub owner used for releases & updates  |
| `BACKWALL_GH_REPO`     | `BackWall`             | GitHub repo name                          |
| `BACKWALL_CORE_TAG`    | `core`                 | Release tag that hosts the core binary    |
| `BACKWALL_MIRROR_URL`  | _(unset)_              | Fallback download URL for the core binary |

Example:

```bash
BACKWALL_MIRROR_URL="https://my-mirror.example/backwall_core_linux_amd64.tar.gz" backwall
```

---

## How it works

1. **Pick a role** — Iran (server) or Kharej (client).
2. **Choose a transport** and answer a short series of prompts (sensible defaults
   are offered for everything).
3. BackWall writes a `*.toml` config under `BACKWALL_DIR` and a matching
   `backwall-<role><port>.service` systemd unit, then enables and starts it.
4. Manage everything else — restart, logs, status, removal — from the menu.

---

## Distributing the core binary

The tunneling core is shipped via **GitHub Releases** rather than committed to
the repo. Create a release tagged `core` and attach:

- `backwall_core_linux_amd64.tar.gz`
- `backwall_core_linux_arm64.tar.gz`

Each archive should contain the executable named `backwall_core` (the script
also auto-renames a few common upstream names if needed).

---

## Requirements

- Linux with `systemd`
- `bash`, `curl`, `tar`, `jq`, `openssl` (auto-installed on apt / dnf / yum / pacman)
- Root privileges

---

## Disclaimer

This tool is provided for legitimate network engineering, self-hosting, and
connectivity purposes. You are responsible for complying with all applicable
laws and the terms of service of your providers.

---

## License

MIT — see [LICENSE](LICENSE).

Telegram: **@GreatTeejay**
