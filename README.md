# EasyTier Core One-Click Installer

Portable `sh` installer for `easytier-core` and `easytier-cli`.

The script detects the current OS and CPU architecture, downloads the matching
EasyTier release archive, writes a local config file, and installs a startup
service when supported.

## Usage

Interactive mode is recommended because the network secret is hidden while you
type it:

```sh
sh install.sh
```

The installer asks for:

```text
EasyTier network name
EasyTier peer URI list
This node's EasyTier virtual IPv4
EasyTier network secret/key
```

Peer URIs should use EasyTier URI format, for example:

```text
tcp://<peer-host>:<port>,udp://<peer-host>:<port>
```

## Non-Interactive Mode

For automation, pass values with flags:

```sh
sh install.sh \
  --network-name '<network-name>' \
  --peer 'tcp://<peer-host>:<port>' \
  --peer 'udp://<peer-host>:<port>' \
  --ip '<virtual-ip>'
```

The secret can also be provided with `ET_NETWORK_SECRET`, but the interactive
prompt is safer for manual use because it avoids putting the key in shell
history.

## Offline or Mirrored Installation

If GitHub is not reachable, download the matching EasyTier release zip by other
means and run:

```sh
sh install.sh --local-zip /path/to/easytier-release.zip
```

Or point the installer at a mirror:

```sh
sh install.sh --download-base 'https://<mirror-host>/<release-path>'
```

## Compatibility

- Shell: POSIX `sh`; `bash` is not required.
- Download fallback order: `curl`, `wget`, `fetch`, `python3`, `busybox wget`.
- Package-manager fallback for missing tools: `apt`, `dnf`, `yum`, `apk`,
  `pacman`, `zypper`, `opkg`, `pkg`, or Homebrew.
- Service fallback: EasyTier's service helper first, then `systemd`, OpenWrt
  init scripts, macOS `launchd`, and finally a `nohup` background runner for
  minimal Linux/container environments without a service manager. If `crontab`
  exists, the background runner also installs an `@reboot` entry.

## Dry Run

Check OS/architecture detection and selected asset without installing:

```sh
sh install.sh --dry-run
```

## Security

This repository intentionally does not hardcode any private network values:

- no peer server IP or hostname
- no EasyTier network name
- no virtual network address
- no network secret

The network secret is written only to the generated EasyTier config file with
file mode `0600`.
