# OSCP workspace logger

A personal Kali Linux helper for organizing practice engagements and recording terminal sessions with asciinema. It installs zsh commands for general work, initial scans, and individual targets. This is an independent project, not an OffSec tool.

## Requirements

- Kali Linux with Bash and interactive zsh.
- asciinema CLI 3.x or newer (`asciinema rec` and `asciinema convert`).
- QTerminal and a desktop D-Bus session for `setup NAME`. The logging commands can be used without QTerminal.
- Standard utilities used by the script, including `awk`, `sed`, `grep`, `ip`, `less`, and `ps`.

## Install

```bash
bash ./oscp-setup.sh install
source ~/.zshrc
```

Running `bash ./oscp-setup.sh` without an argument also installs it. The installer writes `~/.config/oscp/asciinema-logger.zsh` and `~/.config/oscp/tab-bootstrap.sh`, adds a loader to `~/.zshrc`, and saves the original `~/.zshrc` as `~/.zshrc_oscp_backup` if that backup does not already exist. A new interactive shell prompts for a terminal title.

The default workspace is `$HOME/oscp-test` (`/home/kali/oscp-test` for the standard Kali account). Set `OSCP_BASE_DIR` before starting zsh to use another location:

```bash
export OSCP_BASE_DIR="$HOME/my-workspaces"
```

The override is passed to `setup` tabs as well. The `setup` HTTP_Server tab works from `~/Transfer`; its recording still goes under the active engagement.

## Use

```text
setup NAME       Open the engagement's QTerminal tabs in the current window.
logme [NAME]     Record general work; work in the engagement root.
scanme [NAME]    Record initial scans; work in scans/.
scriptme [NAME]  Confirm a target IP and record in its target directory.
stop-log         End the current recording (also: exit or Ctrl+D).
session-status   Show current engagement, target, and recording paths.
session-files    Show current or last cast and text log paths.
session-play     Replay a cast.
session-log      Read a searchable text log.
refresh-log      Regenerate text from the cast.
session-name NAME  Change the session label and terminal title.
```

`NAME` selects an engagement; otherwise the commands reuse the active engagement recorded in `.active-engagement`, or prompt for one. Existing engagement directories are reused. Names that differ only by case resolve to the first directory's capitalization; ambiguous duplicates must be consolidated manually. Recordings are saved as `.cast` files and converted to searchable `.log` files when they end.

`setup NAME` opens Scanning_1, Scanning_2, Working_1, Working_2, Target, HTTP_Server, NC_1, NC_2, Ligolo, Wireshark, and Responder tabs. Scanning tabs start `scanme`; Working, Ligolo, Wireshark, Responder, and HTTP_Server tabs start `logme`. Target and NC tabs open in the engagement root without recording. The tab names become session titles. `setup` opens tabs only; it does not start the named tools.

## Workspace layout

```text
$HOME/oscp-test/
  .active-engagement
  ENGAGEMENT/
    targets.txt
    credentials/{users,passwords,creds,hashes}.txt
    scans/                  # scan recordings and results
    general-log/            # general and tool-tab recordings
    TARGET_IP/
      terminal_*.cast
      terminal_*.log
      working/              # nonstandard exploits and transfer files
      screenshots/
      web-documents/
      loot/
```

`scanme` and `logme` initialize the engagement folders; `scriptme` also creates the target folders and adds the IP to `targets.txt`. The target's recordings sit directly in the target directory. The script sets a restrictive file creation mask and permissions for workspace directories, credential files, and finished recordings.

## Uninstall and privacy

```bash
bash ./oscp-setup.sh uninstall
```

Uninstall removes the generated configuration files and the loader line from `.zshrc`, preserving other shell configuration changes and engagement data. It saves a copy of the current `.zshrc` before editing; the original installation backup is retained for manual recovery.

Terminal recordings can contain credentials, tokens, target details, and command output. Keep the workspace and `~/Transfer` outside this Git repository. The repository's `.gitignore` is a guard for new files, not a substitute for reviewing files before committing or publishing. Do not commit exam materials, proof files, screenshots, credentials, casts, or logs.
