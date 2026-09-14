# DangerZone

Anything you drop in here gets retired when you run the orchestrator in action mode.

- `.csv` with `Hostname` and/or `SerialNumber` columns, or
- `.txt` with device names anywhere in it. Tabs, spaces, commas, one per line, a header sentence at the top, whatever. Anything shaped like `XX-something` is treated as a hostname, everything else is ignored.

Duplicates across files are collapsed. The exact list the run used is saved as `targets.csv` next to the logs.

Files in here are gitignored. Nothing but this README ever gets committed.
