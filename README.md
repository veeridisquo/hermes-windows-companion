# Hermes Windows Companion

A deliberately small, community-maintained Windows notification-area companion for an existing native [Hermes Agent](https://github.com/NousResearch/hermes-agent) installation.

It provides shortcuts for checking and controlling the Hermes gateway, starting or stopping the dashboard, opening Hermes Desktop, and opening logs. It delegates Hermes operations to the official `hermes` CLI.

This project is independent and is not affiliated with or endorsed by Nous Research.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or newer
- Hermes Agent v0.20.x available as `hermes` on `PATH`

## Install

Download or clone this repository, then run from its root directory in PowerShell. Administrator rights are not required.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer:

- copies the companion to `%LOCALAPPDATA%\Programs\Hermes Companion`;
- creates a Start Menu entry;
- enables auto-start for the current Windows user;
- launches the tray companion.

To install without auto-start:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoAutoStart
```

The **Start with Windows** tray-menu option can enable or disable auto-start later.

## Use

Right-click the Hermes icon in the Windows notification area. Windows may initially place it behind the notification-area overflow arrow.

- The normal Hermes icon means the gateway or dashboard is running.
- A dimmed Hermes icon means both are stopped or Hermes is unavailable.
- The tray menu and tooltip show the detailed state.
- Double-click: open or start the Hermes dashboard.

Exiting Hermes Companion closes only the tray application. It does not stop the gateway or dashboard.

## Uninstall

Run the installed uninstaller:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\Hermes Companion\Uninstall.ps1"
```

This removes only Hermes Companion and its shortcuts. It does not change Hermes Agent, gateway tasks, configuration, approvals, or credentials.

## Privacy and security

Hermes Companion has no telemetry, updater, or outbound network client. It opens the local loopback dashboard and invokes the locally installed `hermes` CLI only when needed for status checks or an action you select. Hermes Agent itself may use the network according to its own configuration.

The companion does not read `.env`, `auth.json`, provider tokens, gateway credentials, or model configuration. It does not change Hermes approval settings and never uses `--yolo`.

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Artwork

The Hermes Agent icon comes from the official [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) project. The PNG renders the live tray icon, while the ICO is used for Windows shortcuts. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Current limitations

- Status detection consumes the human-readable output of Hermes v0.20.x because the relevant CLI commands do not currently expose structured JSON output.
- Dashboard health also checks the local loopback port. If Hermes loses track of a dashboard it launched, an explicit **Stop Dashboard** action can stop the verified Hermes process listening on that port.
- The first `hermes desktop` launch may take time while Hermes prepares the Desktop application.
- There is no settings window, updater, telemetry, or chat UI.

## Contributing

Bug reports and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Hermes Windows Companion is available under the [MIT License](LICENSE). The bundled Hermes Agent artwork has separate attribution in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
