# regshot2msi — convert a captured EXE install into an MSI

`regshot2msi` turns a **Regshot Advanced "UNL" capture** of an installer's changes
into a **WiX source file (`.wxs`)** that the WiX Toolset compiles into a Windows
Installer package (`.msi`).

Regshot Advanced already exports NSIS and Inno Setup **scripts** (which compile to
`.exe` installers). MSI is different: it is a compiled database, not a text script,
so it cannot be written directly. The standard route is to generate a WiX source
file and let WiX build the `.msi`. That is exactly what this tool does — and it is
completely decoupled from the Regshot GUI: it only reads a file the tool already
produces, so no changes to the application are required.

```
 ┌────────────┐   1st + 2nd shot    ┌───────────────┐   export UNL   ┌────────────┐
 │ installer  │ ───────────────────▶│ Regshot diff  │ ──────────────▶│ capture.unl│
 │   .exe     │                     └───────────────┘                └─────┬──────┘
 └────────────┘                                                            │
                                              regshot2msi.py               ▼
                                        ┌───────────────┐   wix build  ┌────────┐
                                        │  capture.wxs  │ ────────────▶│  .msi  │
                                        └───────────────┘              └────────┘
```

## Requirements

* **Python 3.6+** to run the converter (no third-party packages).
* **WiX Toolset v4 or v5** to build the `.msi`:
  ```
  dotnet tool install --global wix
  ```

## Usage

1. In **Regshot Advanced**: take the 1st shot, run the installer `.exe`, take the
   2nd shot, then **Compare**. Enable the **UNL** output format so a `.unl` file is
   written next to the other reports.

2. Convert the capture to WiX source:
   ```
   python regshot2msi.py capture.unl -o MyApp.wxs --title "MyApp" --manufacturer "My Company"
   ```

3. Build the MSI with WiX:
   ```
   wix build MyApp.wxs -o MyApp.msi
   ```
   The files referenced by the capture must still exist at their captured paths
   when `wix build` runs — WiX stages them into the `.msi` at build time (the same
   assumption Regshot's built-in NSIS/Inno exports make).

## Options

| Option | Purpose |
| ------ | ------- |
| `-o`, `--output` | Output `.wxs` path (default: alongside the input). |
| `--title` | Product name (default: input file name). Also names the install folder. |
| `--manufacturer` | Company/manufacturer string. |
| `--version` | Product version, `w.x.y.z` (default `1.0.0.0`). |
| `--install-root` | MSI root for staged files: `ProgramFiles64Folder` (default), `ProgramFilesFolder`, `CommonAppDataFolder`, … |
| `--strip-prefix` | Capture path prefix to strip before staging files, e.g. `"C:\Program Files\MyApp"`. By default only the drive letter is stripped, so files keep their original folder structure under the install root. |
| `--direction` | `install` (default) stages the *added* items; `uninstall` builds a package from the *removed* items. |
| `--encoding` | Force the input encoding (default: auto-detect UTF‑16/UTF‑8). |

## What gets converted

| Capture entry | MSI result |
| ------------- | ---------- |
| Added registry key | Registry key created (empty default value as key-path). |
| Added/changed registry value | `<RegistryValue>` with the correct type (below). |
| Added file | `<File>` staged into the MSI under the install root, preserving folders. |
| Added directory | `<CreateFolder>` (for directories with no captured files). |
| **Removed** items | Ignored for `install`; used for `--direction uninstall`. |

Registry value types are recovered from the standard `.reg` encoding Regshot writes:

| Capture data | Registry type | WiX `Type` |
| ------------ | ------------- | ---------- |
| `"text"` | REG_SZ | `string` |
| `dword:0000000a` | REG_DWORD | `integer` |
| `hex:xx,xx` | REG_BINARY | `binary` |
| `hex(2):…` | REG_EXPAND_SZ | `expandable` |
| `hex(7):…` | REG_MULTI_SZ | `multiString` |
| `hex(b):…` | REG_QWORD | `binary` \* |
| `hex(0):` | REG_NONE | `binary` \* |

\* Windows Installer has no native registry type for QWORD/NONE, so the raw bytes
are written as binary.

## Registry roots

`HKLM`, `HKCU`, `HKU`, `HKCR` (both short and long `HKEY_*` spellings) are mapped to
the corresponding WiX `Root` values.

## Limitations (v1)

* Files are staged from their **captured absolute paths**, which must exist at build
  time. Use `--strip-prefix` to control where they land.
* Registry key/value **names are assumed not to contain embedded double quotes**.
* Very long binary/multi-string values that Regshot wraps across lines are
  re-joined best-effort using `.reg` backslash-continuation rules.
* `perMachine` scope is used; `HKCU` writes then follow Windows Installer's
  per-user registry handling.

## Tests

```
python -m unittest test_regshot2msi -v
```

`sample-capture.unl` is a small hand-written capture you can convert to see the
output shape:

```
python regshot2msi.py sample-capture.unl -o sample.wxs
```
