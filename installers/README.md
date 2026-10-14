# Installers

Double-click these from Explorer (Windows). Each one opens a console, says what it's doing,
and waits for a key press at the end.

| Script | What it does |
|---|---|
| **GenFill-Setup.cmd** | The graphical installer for artists (same as `dist\GenFill-Setup.exe`). Installs, updates, repairs or uninstalls the plugin and, optionally, the free local AI, in one window. See [GenFill Setup](#genfill-setup). |
| **install.bat** | Runs the unit tests, then installs a fresh copy of the current build to `%USERPROFILE%\.nuke\plugins\GenFill` and makes your Nuke `init.py` load it. Run it every time you want to test the latest code. |
| **install_and_launch.bat** | Same, then starts the newest Nuke it finds. |
| **install_dev.bat** | Points Nuke straight at this repo instead of copying. Edits are live after a restart or **GenFill > Developer > Reload GenFill**. |
| **uninstall.bat** | Removes the installed build and the init.py block. Keeps your API keys and generated images. |
| **run_smoke_test.bat** | Runs the smoke test in Nuke's terminal mode (needs a license that allows `nuke -t`). |

## GenFill Setup

`GenFill-Setup.ps1` is a WPF app (Windows PowerShell 5.1, nothing to install). Pages: Welcome
(Nuke versions, GPU, installed and latest version), Options, Install (per-step progress, details
log, Cancel), Finish (start a Nuke version). With `-Uninstall` it opens on the Uninstall page.

- **Source:** the latest `main` from GitHub, or the repo it sits in (it offers both when run from
  a checkout). No tests are run; use `install.bat` for that.
- **Plugin:** the same copy + `build_info.json` + managed `init.py` block as `install.ps1`, with the
  same markers, so the two installers can be mixed freely.
- **Nuke versions:** *Load in* lists the Nuke versions found (by major.minor) plus *Other and future
  versions*. All on (the default) writes the plain block. Otherwise the block wraps
  `pluginAddPath` in a check on `(nuke.NUKE_VERSION_MAJOR, nuke.NUKE_VERSION_MINOR)`, and
  the setup reads that check back to preselect the same versions on the next update. Nuke 12
  and older (Python 2) can't be selected. Note that `install.bat` writes the plain block.
- **Local AI:** runs the plugin's own `genfill.localai.installer` with the newest Nuke's
  `python.exe` (no new Python needed) and streams its events into the window. Same steps,
  resume and logs as **GenFill > Local AI > Install / Repair** in Nuke.
- **Windows:** registers *GenFill for Nuke* under `HKCU\...\Uninstall\GenFill` (per-user, no
  admin) and keeps a copy of the setup in `%LOCALAPPDATA%\GenFill\Setup` for uninstalling.
- **Log:** `%TEMP%\GenFill-Setup.log` (**Open log** on the last page).
- **Credits:** the sidebar names GenFill's author (Connor Thomas) and the setup's (Aleš Ushakou);
  **Credits** opens a page with both and the third-party models and libraries with their licenses.

Build the single-file exe with:

```powershell
.\build_setup.ps1        # -> dist\GenFill-Setup.exe (+ GenFill.ico)
```

It compiles `setup\GenFillSetup.cs` with the .NET Framework `csc.exe` that ships with Windows; the
exe embeds `GenFill-Setup.ps1` and runs it in-process (no console window). The exe is unsigned, so
Windows SmartScreen asks for confirmation the first time (**More info > Run anyway**).

`.\GenFill-Setup.ps1 -Snapshot <folder>` renders every page to PNG and exits (for checking the
layout or making screenshots).

## What install does, exactly

1. Finds your Nuke installs under Program Files.
2. Runs `python -m unittest discover -s tests` using **Nuke's own python.exe**, so the tests run
   on the same Python version Nuke uses. If they fail, nothing is installed (`-Force` overrides).
3. Deletes the previous build and copies `nuke\` to the install folder.
4. Writes `build_info.json` into the build: version, git commit (with `*` if you have
   uncommitted changes) and time. Nuke prints this at startup and shows it under
   **GenFill > Developer > Build Info**, so you always know which build you're testing.
5. Backs up `%USERPROFILE%\.nuke\init.py` to `init.py.genfill-backup`, then adds or updates one
   clearly marked block:

   ```python
   # >>> GenFill (managed by GenFill installers\install.ps1 - edits here are overwritten) >>>
   import nuke
   nuke.pluginAddPath(r"C:\Users\you\.nuke\plugins\GenFill")
   # <<< GenFill <<<
   ```

   Any hand-written GenFill `pluginAddPath` line elsewhere in init.py gets commented out so the
   plugin doesn't load twice. Everything else in your init.py is left alone.
6. Warns you if Nuke is already open.

## Options (PowerShell)

```powershell
.\install.ps1 -Mode dev                     # live from repo
.\install.ps1 -SkipTests                    # don't run tests
.\install.ps1 -Force                        # install even if tests fail
.\install.ps1 -Target D:\nuke\GenFill       # different install folder (name must contain GenFill)
.\install.ps1 -Launch -NukeArgs "--nukex"   # start NukeX after installing
```

## Testing a build in Nuke

After installing, in Nuke: **GenFill > Developer > Run Smoke Test**. It builds a throwaway
setup inside a Group called `GenFill_SmokeTest`, generates with the offline backend (no key or
network needed), renders the results and writes everything to `test_output\` in this repo:

- `report.json`: pass/fail per step with tracebacks, Nuke and Python versions, and which knobs
  exist on this Nuke version
- `comp.png`, `fill.png`: what the node outputs
- `source.png`, `mask.png`, `var_01.png`: what went to and came back from the model
- `panel.png`: a screenshot of the GenFill panel

Claude can read `test_output\` directly, so after a run you can just say "check the smoke test".

## Local AI

The free local model is installed from inside Nuke, not from here:
**GenFill > Local AI > Install / Repair...**. See the main README.
