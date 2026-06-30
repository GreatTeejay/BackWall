# Changelog

## v2.0.0 — BackWall (Teejay Edition)

Full rebrand and hardening of the original Backhaul-based tunnel script.

### Rebrand
- Renamed project to **BackWall — Teejay Edition**.
- Unified all paths, binary name, and systemd units under `backwall`
  (`/root/backwall-core`, `backwall_core`, `backwall-<role><port>.service`).
- Updated all download/update URLs to the `GreatTeejay/BackWall` GitHub repo.

### Fixed
- **Self-update is no longer dead code.** The previous `update_script` began
  with a bare `return`, so it never ran. It now downloads, sanity-checks, and
  installs the latest script over HTTPS.
- Fixed the `bbackhaul` typo in the TUN forwarder prompt (now `backwall`).
- TOML `connection_pool` no longer emitted when set to `0`.

### Security & robustness
- Core binary now downloads over **HTTPS via GitHub Releases** (was plain HTTP
  from a hardcoded IP).
- Self-update verifies the payload looks like BackWall before installing.
- Self-signed certs generated quietly; PSK now defaults to a freshly generated
  random value instead of a shipped constant.

### Quality
- Removed all code obfuscation — the script is now fully readable.
- Centralised configuration at the top of the file, overridable via env vars
  (`BACKWALL_DIR`, `BACKWALL_GH_OWNER`, `BACKWALL_GH_REPO`, `BACKWALL_CORE_TAG`,
  `BACKWALL_MIRROR_URL`).
- Dependency installer now supports apt, dnf, yum, and pacman.
- Added an `in_list` helper and tidied membership checks.
- Passes `shellcheck -S warning` with zero warnings.
- Added README, LICENSE (MIT), install.sh, .gitignore, and a release workflow.
