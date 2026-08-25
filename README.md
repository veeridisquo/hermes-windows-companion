# Hermes Windows Companion

A deliberately small, community-maintained Windows notification-area companion for an existing native [Hermes Agent](https://github.com/NousResearch/hermes-agent) installation.

It provides shortcuts for checking and controlling the Hermes gateway, starting or stopping the dashboard, opening Hermes Desktop, and opening logs. It delegates Hermes operations to the official `hermes` CLI.

This project is independent and is not affiliated with or endorsed by Nous Research.

## Requirements

- Windows 10 or Windows 11
- Windows Terminal, to open a profile in a terminal. A console window is used when it is absent.
- Windows PowerShell 5.1 or newer
- Hermes Agent v0.20.5 or newer available as `hermes` on `PATH`

## Install

Keep the repository in a permanent location, then run from PowerShell inside
the checkout. Administrator rights are not required.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer:

- runs the companion directly from the source checkout;
- creates a Start Menu entry;
- enables auto-start for the current Windows user;
- launches the tray companion.

The shortcuts point to the checkout, so rerun `Install.ps1` if the repository
is moved.

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
- The tray menu shows the installed Hermes version and whether an update is available.
- **Hermes profiles** lists every profile with its gateway state and marks the active one.
- Double-click: open or start the Hermes dashboard.

Each profile has a submenu to open Hermes in a terminal with that profile, view its details, open its folder, and control its gateway. A profile without a Windows background gateway shows **Install gateway...** instead of allowing Start. The installer opens in a terminal because Hermes may ask for confirmation or Windows may ask for administrator approval. Terminals open in Windows Terminal when it is installed, and in a console window otherwise.

**Check for updates** runs `hermes update --check`, the documented way to ask whether an update is available. It always contacts the upstream repository, so the answer is never a cached one. **Update Hermes...** installs the newest version in the background.

While an update runs, the tray tooltip and the menu show the current step and the elapsed time, a balloon reports progress every five minutes, and **Open update log** shows the full output. When the update ends, the balloon reports the version change. If Hermes finished but left something to act on, such as local changes it could not restore, those notes are shown in a dialog rather than left in the log.

Exiting Hermes Companion closes only the tray application. It does not stop the gateway or dashboard.

## Uninstall

Run from the source checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

This stops the companion and removes its shortcuts. It leaves the source
checkout in place and does not change Hermes Agent, gateway tasks,
configuration, approvals, or credentials.

## Privacy and security

Hermes Companion has no telemetry and no network client of its own. It opens the local loopback dashboard and invokes the locally installed `hermes` CLI only when needed for status checks or an action you select. Profile information comes from `hermes profile list` and `hermes profile show`, read at startup and whenever you select **Refresh status**. Hermes Agent itself may use the network according to its own configuration.

The version and update status come from `hermes --version` at startup. That command is a Hermes feature: Hermes contacts its own upstream git remote and caches the result for six hours. **Check for updates** runs `hermes update --check`, which always fetches. Installing an update runs `hermes update` the way the Hermes web dashboard runs it: with `HERMES_NONINTERACTIVE=1`, stdin closed, and output merged into one log. Hermes then answers its own prompts from `updates.non_interactive_local_changes` rather than waiting for input that cannot arrive.

The companion does not read `.env`, `auth.json`, provider tokens, gateway credentials, or model configuration. It does not change Hermes approval settings and never uses `--yolo`.

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Artwork

The tray icon comes from the official [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) project.

`hermes-agent.ico` carries the artwork at 16, 20, 24, 32, 48, 64, 128, and 256 pixels. The companion loads the size the notification area asks for, so the tray icon is never rescaled. `hermes-agent.png` is the 256x256 master the `.ico` was generated from. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Current limitations

- Status detection consumes the human-readable output of the Hermes CLI, because the relevant commands do not expose structured output. A Hermes release that renames a command or reworks its output can break it. Hermes v0.20.5 removed the `hermes version` subcommand in favour of `hermes --version`, which is what Hermes Companion now calls.
- Dashboard health also checks the local loopback port. If Hermes loses track of a dashboard it launched, an explicit **Stop Dashboard** action can stop the verified Hermes process listening on that port.
- The first `hermes desktop` launch may take time while Hermes prepares the Desktop application.
- There is no settings window, telemetry, or chat UI. Hermes Companion delegates updates to `hermes update` and never updates itself.
- The update runs without a console window. Progress is read from the update log and shown in the tooltip, the menu, and a balloon every five minutes.
- Hermes refuses to update while any process holds its Python environment, because a dependency sync that dies partway strands the install between versions. Before an update, Hermes Companion lists every such process in the confirmation dialog and stops it. Unsaved work in those processes is lost. The dashboard is started again afterwards. The gateway is left alone, because Hermes pauses and restarts it itself.
- Hermes Companion never passes `--force` or `--force-venv`. Those skip the guards that keep a failed update from corrupting the install.
- Only a git installation can be updated in place. For a Docker, Nix, or Termux install, Hermes Companion shows the update command Hermes recommends instead of running one.

## Development

Run the parser suite with Windows PowerShell 5.1:

```powershell
Invoke-Pester -Path .\tests
```

## Contributing

Bug reports and focused pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Hermes Windows Companion is available under the [MIT License](LICENSE). The bundled Hermes Agent artwork has separate attribution in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
