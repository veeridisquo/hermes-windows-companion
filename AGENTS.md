# Development workflow

- After implementing any new feature, restart the Windows tray companion from this checkout before reporting completion, so Daniel can test the change immediately.
- Restart only the companion process whose command line references this checkout's `HermesCompanion.ps1`. Do not stop Hermes gateways, dashboards, or unrelated PowerShell processes.
- Verify that the replacement companion process is running.
