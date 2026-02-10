# ubuntu-unsnap-hardening
A shell script that safely removes all traces of snap binaries and most Canonical telemetry from Ubuntu
# Ubuntu Unsnap Hardening Script

## Description and Purpose:

This project provides a **production-grade hardening script for Ubuntu** that permanently removes Snap and Snap-dependent components, replaces Canonical’s Snap-centric application workflow with an **APT- and Flatpak-first model**, installs **real `.deb` builds of Firefox and Thunderbird from Mozilla-controlled sources**, and disables **Canonical/Ubuntu telemetry and reporting**.  

As a project, the script was originally intended and especially suitable for **"vanilla-Gnome"** desktop configurations.

The script is designed to be **safe, idempotent, and self-healing**: it can be run repeatedly, survives system upgrades, and automatically re-enforces policy if Ubuntu attempts to reintroduce Snap, Snap Store, or related transition packages.

It is suitable for:
- Security-conscious desktops and laptops
- Developer workstations
- Controlled enterprise or research environments
- Long-lived systems that undergo release upgrades

---

## Design Principles

### 1. Explicit Control Over Software Sources
Ubuntu increasingly uses **Snap transition packages** that silently reintroduce Snap during upgrades. This script avoids that by:
- Purging Snap, Snapd, and Snap Store components
- Blocking reinstallation via **APT pinning and package holds**
- Installing browsers only from **Mozilla-controlled repositories**

This ensures updates remain transparent, auditable, and under administrator control.

---

### 2. Idempotent, Re-Runnable by Design
The script is safe to run:
- Multiple times
- After upgrades
- After partial failures

Key techniques:
- Configuration files are **written to fixed paths**, never appended
- Services are **stopped, disabled, and masked** (masking is idempotent)
- Package removals are **best-effort and guarded**
- Errors are **trapped, logged, and summarized**, not fatal

---

### 3. Upgrade-Resilient Reinforcement
Ubuntu upgrades frequently:
- Reinstall Snap
- Re-enable telemetry
- Replace Firefox/Thunderbird with Snap stubs

To prevent drift, the script installs **post-upgrade reinforcement hooks** that:
- Re-apply Snap blocks and pins
- Re-assert Mozilla package sourcing
- Re-disable telemetry and reporting
- Optionally re-run after every `apt update` (flag-controlled)

---

## Core Features & Capabilities

### Snap Removal & Prevention
- Removes **all snaps**, including:
  - snapd
  - snap-store / Ubuntu App Center
  - desktop integration snaps
  - core runtime snaps
- Deletes Snap residue directories
- Masks Snap systemd units
- Prevents reinstallation using:
  - APT pinning
  - `apt-mark hold`
  - Post-upgrade enforcement

---

### APT + Flatpak Application Workflow
- Replaces Snap Store with:
  - `gnome-software`
  - `gnome-software-plugin-flatpak`
- Removes Snap plugin for GNOME Software
- Installs Flatpak and configures **Flathub**
- Leaves the system GUI-friendly while fully Snap-free

---

### Firefox & Thunderbird (Real `.deb` Builds)
**Firefox**
- Installed from Mozilla’s official APT repository (`packages.mozilla.org`)
- Highest APT priority
- Explicitly blocked from Ubuntu and PPA sources

**Thunderbird**
- Installed from `ppa:mozillateam/ppa`
- Explicit PPA detection (no duplicate repo entries)
- Explicitly prevented from pulling Firefox from the same PPA

**Result:**  
No Snap stubs, no transitional packages, no silent replacements during upgrades.

---

### Telemetry & Reporting Removal
The script disables or removes:
- `ubuntu-report`
- `popularity-contest`
- `whoopsie`
- `apport` (service + config)
- MOTD “news” and Livepatch banners
- Ubuntu Pro / UA background timers

This reduces:
- Unwanted network calls
- Background services
- Noise in hardened or offline environments

---

### Logging & Observability
- Central log file: `/var/log/unsnap-hardening.log`
- Reinforcement log: `/var/log/unsnap-hardening-reinforce.log`
- Errors are:
  - Reported at runtime
  - Summarized at completion
- Designed for audit and troubleshooting, not silent failure

---

## Supported Systems

- Ubuntu 25.04
- Ubuntu 25.10
- Ubuntu 26.04 (tested assumptions)
- Both `amd64` and `arm64`

The script detects:
- Ubuntu version
- Codename
- Architecture
and adapts repository handling accordingly.

---

## Intended Use Cases

- Personal systems where Snap is undesirable
- Regulated or restricted environments
- Developers who need predictable packaging
- Long-term systems that must survive release upgrades without policy drift

---

## Summary

This script establishes a **clean, controlled, Snap-free Ubuntu baseline** that:
- Respects administrator intent
- Survives upgrades
- Remains transparent and auditable
- Avoids fragile hacks or one-off tweaks

Runing the script with `sudo` safely converts an Ubuntu installation into a **Debian-style system**, through opinionated and documented policy decisions, while preserving modern desktop usability.

---
## License

This is really, simple and well-defined shell logic that leverages best-practices and previously published guidance for policy-based use of `apt` tooling and Debian-style software packaging. It's an unfortunate fact that some form of license is required for the free sharing of such a script. GPL versions seem to be overkill, so we've defaulted to the MIT license. Be generous and respectful. I hope you find this useful.
