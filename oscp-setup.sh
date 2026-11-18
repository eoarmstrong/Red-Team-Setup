#!/usr/bin/env bash

set -euo pipefail
umask 077

ACTION="${1:-install}"

ZSHRC="$HOME/.zshrc"
CONFIG_DIR="$HOME/.config/oscp"
CONFIG_FILE="$CONFIG_DIR/asciinema-logger.zsh"
TAB_BOOTSTRAP_FILE="$CONFIG_DIR/tab-bootstrap.sh"
BACKUP="$HOME/.zshrc_oscp_backup"

SOURCE_LINE='[[ -f "$HOME/.config/oscp/asciinema-logger.zsh" ]] && source "$HOME/.config/oscp/asciinema-logger.zsh"'

info() { printf '[+] %s\n' "$*"; }
note() { printf '[=] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }

install_logger() {
    command -v asciinema >/dev/null 2>&1 || die "asciinema was not found."

    local version major stamp
    version="$(asciinema --version 2>/dev/null | awk '{print $NF}')"
    major="${version%%.*}"

    if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 3 )); then
        die "asciinema CLI 3.x is required. Found: ${version:-unknown}"
    fi

    mkdir -p "$CONFIG_DIR"
    touch "$ZSHRC"

    if [[ ! -e "$BACKUP" ]]; then
        cp -a "$ZSHRC" "$BACKUP"
        info "Backed up original ~/.zshrc to ~/.zshrc_oscp_backup"
    else
        note "Existing ~/.zshrc backup preserved: ~/.zshrc_oscp_backup"
    fi

    # Keep prior generated files when reinstalling over a customized setup.
    stamp="$(date -u '+%Y%m%d_%H%M%S_UTC')_$$"
    if [[ -e "$CONFIG_FILE" ]]; then
        cp -a "$CONFIG_FILE" "${CONFIG_FILE}.before-install_${stamp}"
        note "Saved existing logger config before reinstalling."
    fi
    if [[ -e "$TAB_BOOTSTRAP_FILE" ]]; then
        cp -a "$TAB_BOOTSTRAP_FILE" "${TAB_BOOTSTRAP_FILE}.before-install_${stamp}"
        note "Saved existing tab helper before reinstalling."
    fi

    cat > "$CONFIG_FILE" <<'ZSH'
# ============================================================
# OSCP On-Demand Workspace & asciinema Logger
#
# - Prompts once on an interactive shell open for a local terminal label.
# - The recorded asciinema child shell skips that prompt.
# - Run 'logme' from the engagement root; recordings go in general-log/.
# - Add an engagement name to any logger command to switch before recording:
#   'logme NAME', 'scanme NAME', or 'scriptme NAME'.
# - Run 'scanme' for initial discovery before a target IP is selected.
# - Run 'scriptme' whenever you want to set a target IP,
#   create folders/files, and start target logging.
# - The selected engagement is remembered in $OSCP_BASE_DIR/.active-engagement.
# - Engagement names reuse the first directory's capitalization.
# - Conflicting directories that differ only by case must be consolidated manually.
# - Every engagement has scans/, credentials/, general-log/, and targets.txt.
# - Each target IP folder holds recordings, working/, screenshots/, web-documents/, and loot/.
# - working/ is for exploit files and transfer items that are not part of ~/Transfer.
# - Run 'setup NAME' to open that engagement's QTerminal workspace tabs.
# ============================================================

[[ -o interactive ]] || return 0

autoload -Uz add-zsh-hook

typeset -g OSCP_BASE_DIR="${OSCP_BASE_DIR:-$HOME/oscp-test}"
export OSCP_BASE_DIR
typeset -g OSCP_ENGAGEMENT="${OSCP_ENGAGEMENT:-}"
typeset -g OSCP_ENGAGEMENT_PATH="${OSCP_ENGAGEMENT_PATH:-}"
typeset -g OSCP_ACTIVE_ENGAGEMENT_FILE="$OSCP_BASE_DIR/.active-engagement"
typeset -g IP="${IP:-}"
typeset -g TARGET_PATH="${TARGET_PATH:-}"
typeset -g OSCP_SESSION_NAME="${OSCP_SESSION_NAME:-}"
typeset -g OSCP_RECORDING_MODE="${OSCP_RECORDING_MODE:-}"
typeset -g OSCP_CAST_FILE="${OSCP_CAST_FILE:-}"
typeset -g OSCP_TEXT_FILE="${OSCP_TEXT_FILE:-}"
typeset -g OSCP_LAST_CAST="${OSCP_LAST_CAST:-}"
typeset -g OSCP_LAST_TEXT="${OSCP_LAST_TEXT:-}"
typeset -g OSCP_SHELL_TITLE="${OSCP_SHELL_TITLE:-Kali}"
typeset -g OSCP_TAB_BOOTSTRAP_MODE="${OSCP_TAB_BOOTSTRAP_MODE:-}"
typeset -g OSCP_TAB_BOOTSTRAP_WORKDIR="${OSCP_TAB_BOOTSTRAP_WORKDIR:-}"
typeset -g _OSCP_TIPS_SHOWN="${_OSCP_TIPS_SHOWN:-0}"
typeset -g _OSCP_SHELL_TITLE_PROMPTED="${_OSCP_SHELL_TITLE_PROMPTED:-0}"

# -----------------------------
# Utility helpers
# -----------------------------

_oscp_slug() {
    local s="${1:-}"
    s="${s//[^A-Za-z0-9._-]/_}"
    [[ -n "$s" ]] || s="session"
    print -r -- "$s"
}

_oscp_resolve_engagement_name() {
    local requested="$(_oscp_slug "${1:-}")" candidate match=""

    if [[ "$requested" == "." || "$requested" == ".." ]]; then
        print -r -- "[-] Engagement name cannot be . or .." >&2
        return 1
    fi

    if [[ -d "$OSCP_BASE_DIR" ]]; then
        [[ -r "$OSCP_BASE_DIR" && -x "$OSCP_BASE_DIR" ]] || {
            print -r -- "[-] Cannot read engagement directory: $OSCP_BASE_DIR" >&2
            return 1
        }

        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            if [[ -n "$match" ]]; then
                print -r -- "[-] Engagement '$requested' matches both $OSCP_BASE_DIR/$match and $OSCP_BASE_DIR/$candidate" >&2
                print -r -- "[=] Consolidate these directories before continuing; no engagement files were changed." >&2
                return 1
            fi
            match="$candidate"
        done < <(command env LC_ALL=C find "$OSCP_BASE_DIR" -mindepth 1 -maxdepth 1 -iname "$requested" -printf '%f\n' 2>/dev/null)
    elif [[ -e "$OSCP_BASE_DIR" || -L "$OSCP_BASE_DIR" ]]; then
        print -r -- "[-] Engagement base path is not a directory: $OSCP_BASE_DIR" >&2
        return 1
    fi

    if [[ -n "$match" ]]; then
        [[ -d "$OSCP_BASE_DIR/$match" ]] || {
            print -r -- "[-] Engagement name is occupied by a file: $OSCP_BASE_DIR/$match" >&2
            return 1
        }
        print -r -- "$match"
    else
        print -r -- "$requested"
    fi
}

_oscp_default_session_name() {
    local name="${OSCP_SESSION_NAME:-${OSCP_SHELL_TITLE:-${IP:-Kali}}}"
    print -r -- "$(_oscp_slug "$name")"
}

_oscp_prompt_session_title() {
    local default_name="${1:-$(_oscp_default_session_name)}" entered_name

    # QTerminal workspace tabs already have their chosen labels.
    if [[ -n "${OSCP_TAB_BOOTSTRAP_MODE:-}" ]]; then
        OSCP_SESSION_NAME="$(_oscp_slug "${OSCP_SESSION_NAME:-$default_name}")"
        export OSCP_SESSION_NAME
        return 0
    fi

    print -Pn "%F{cyan}[?]%f Session/Tab title %F{white}[Enter for ${default_name}]%f: "
    read -r entered_name
    OSCP_SESSION_NAME="$(_oscp_slug "${entered_name:-$default_name}")"
    export OSCP_SESSION_NAME
}

_oscp_read_active_engagement() {
    local name

    [[ -f "$OSCP_ACTIVE_ENGAGEMENT_FILE" ]] || return 1
    name="$(command sed -n '1p' "$OSCP_ACTIVE_ENGAGEMENT_FILE" 2>/dev/null || true)"
    [[ -n "$name" ]] || return 1
    print -r -- "$(_oscp_slug "$name")"
}

_oscp_set_active_engagement() {
    local name="${1:-}"

    [[ -n "$name" ]] || return 1
    name="$(_oscp_resolve_engagement_name "$name")" || return 1
    (umask 077; command mkdir -p -- "$OSCP_BASE_DIR"; print -r -- "$name" > "$OSCP_ACTIVE_ENGAGEMENT_FILE") || return 1
    command chmod 600 -- "$OSCP_ACTIVE_ENGAGEMENT_FILE" 2>/dev/null || true

    OSCP_ENGAGEMENT="$name"
    OSCP_ENGAGEMENT_PATH="$OSCP_BASE_DIR/$name"
    export OSCP_ENGAGEMENT OSCP_ENGAGEMENT_PATH
}

_oscp_select_engagement() {
    local requested="${1:-}" selected

    if [[ -n "$requested" ]]; then
        selected="$requested"
    elif [[ -n "${OSCP_ENGAGEMENT:-}" ]]; then
        selected="$OSCP_ENGAGEMENT"
    else
        selected="$(_oscp_read_active_engagement 2>/dev/null || true)"
    fi

    if [[ -z "$selected" ]]; then
        print -Pn "%F{cyan}[?]%f Engagement name: "
        read -r selected
    fi

    [[ -n "$selected" ]] || {
        print -P "%F{yellow}[!] Engagement name cannot be empty.%f"
        return 1
    }

    _oscp_set_active_engagement "$selected"
}

_oscp_initialize_engagement() {
    local scan_path="$OSCP_ENGAGEMENT_PATH/scans"
    local credentials_path="$OSCP_ENGAGEMENT_PATH/credentials"
    local general_log_path="$OSCP_ENGAGEMENT_PATH/general-log"
    local targets_file="$OSCP_ENGAGEMENT_PATH/targets.txt"

    # Initialize engagement-level resources for both scanme and scriptme.
    (umask 077; command mkdir -p -- "$scan_path" "$credentials_path" "$general_log_path"; command touch -- "$targets_file"; command touch -- \
        "$credentials_path/users.txt" \
        "$credentials_path/passwords.txt" \
        "$credentials_path/creds.txt" \
        "$credentials_path/hashes.txt") || return 1
    command chmod 600 -- "$targets_file" 2>/dev/null || true
    command chmod 600 -- \
        "$credentials_path/users.txt" \
        "$credentials_path/passwords.txt" \
        "$credentials_path/creds.txt" \
        "$credentials_path/hashes.txt" 2>/dev/null || true
    command chmod 700 -- "$OSCP_BASE_DIR" "$OSCP_ENGAGEMENT_PATH" "$scan_path" "$credentials_path" "$general_log_path" 2>/dev/null || true
}
_oscp_stamp() {
    command date -u '+%Y%m%d_%H%M%S_UTC'
}

_oscp_tun_ip() {
    local ipaddr
    ipaddr="$(
        command ip -4 -o addr show tun0 2>/dev/null \
        | command awk '{print $4}' \
        | command cut -d/ -f1 \
        | command head -n1
    )"
    [[ -n "$ipaddr" ]] && print -r -- "$ipaddr" || print -r -- "NO-VPN"
}

_oscp_state() {
    [[ -n "${ASCIINEMA_SESSION:-}" ]] && print -r -- "LOG" || print -r -- "NOLOG"
}

_oscp_show_tips() {
    (( _OSCP_TIPS_SHOWN )) && return 0
    _OSCP_TIPS_SHOWN=1

    print
    print -P "%F{cyan}OSCP logger tips:%f"
    print -P "  %F{green}logme%f                log general work in the active engagement"
    print -P "  %F{green}logme NAME%f           select an engagement, then log general work"
    print -P "  %F{green}scanme%f               log initial scans in the active engagement"
    print -P "  %F{green}scanme NAME%f          select an engagement, then log initial scans"
    print -P "  %F{green}scriptme%f             set target IP, scaffold folders, and start logging"
    print -P "  %F{green}scriptme NAME%f        select an engagement, then set target IP"
    print -P "  %F{green}setup NAME%f           open QTerminal tabs for an engagement"
    print -P "  %F{green}session-status%f       show current target, session, and log paths"
    print -P "  %F{green}session-name NAME%f    change the [session] field and terminal title"
    print -P "  %F{green}stop-log%f             stop the current recorded shell (or type 'exit')"
    print -P "  %F{green}session-play%f         replay the last .cast recording"
    print -P "  %F{green}session-log%f          open the last searchable .log"
    print -P "  %F{green}refresh-log%f          regenerate searchable text from the cast"
    print -P "  %F{green}session-files%f        print the current/last recording paths"
    print -P "  %F{green}session-help%f         show these tips again"
    print
    print -P "%F{yellow}Search all logs across targets:%f"
    print "  rg -n 'SEARCH_TERM' \"$OSCP_BASE_DIR\""
    print
}

session-help() {
    _OSCP_TIPS_SHOWN=0
    _oscp_show_tips
}

# -----------------------------
# Prompt
# -----------------------------

_oscp_prompt_update() {
    local state state_color utc tun_ip session title

    state="$(_oscp_state)"
    utc="$(command date -u '+%Y-%m-%d %H:%M:%S UTC')"
    tun_ip="$(_oscp_tun_ip)"
    session="${OSCP_SESSION_NAME:-${IP:-NO-SESSION}}"

    if [[ "$state" == "LOG" ]]; then
        state_color="green"
    else
        state_color="yellow"
    fi

    PROMPT="%F{${state_color}}[${state}]%f %F{blue}[${session}]%f %F{green}%n@%m%f %F{white}%~%f %F{cyan}[${utc}]%f %F{magenta}[tun0:${tun_ip}]%f %F{blue}$%f "

    # Use the target/session title during an engagement; otherwise use the local shell label.
    if [[ -n "${OSCP_SESSION_NAME:-}" || -n "${IP:-}" ]]; then
        title="$session"
    else
        title="${OSCP_SHELL_TITLE:-Kali}"
    fi
    print -Pn "\e]0;${title}\a"
}

add-zsh-hook precmd _oscp_prompt_update

_oscp_shell_title_init() {
    # Do not block noninteractive shells or the nested shell started by asciinema.
    [[ -o interactive ]] || return 0
    [[ -t 0 && -t 1 ]] || return 0
    [[ -n "${ASCIINEMA_SESSION:-}" ]] && return 0
    [[ -n "${OSCP_SESSION_NAME:-}" || -n "${IP:-}" ]] && return 0
    (( _OSCP_SHELL_TITLE_PROMPTED )) && return 0

    _OSCP_SHELL_TITLE_PROMPTED=1
    local entered
    print -Pn "%F{cyan}[?]%f Terminal title %F{white}[Enter for ${OSCP_SHELL_TITLE}]%f: "
    read -r entered

    if [[ -n "$entered" ]]; then
        OSCP_SHELL_TITLE="$(_oscp_slug "$entered")"
        export OSCP_SHELL_TITLE
    fi

    _oscp_prompt_update
}

session-name() {
    local entered newname

    if [[ -n "${1:-}" ]]; then
        entered="$1"
    else
        printf 'New session name: '
        read -r entered
    fi

    newname="$(_oscp_slug "${entered:-session}")"
    OSCP_SESSION_NAME="$newname"
    export OSCP_SESSION_NAME

    _oscp_prompt_update
    print -r -- "[+] Session title: $OSCP_SESSION_NAME"

    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        print -r -- "[=] Active .cast/.log filenames are unchanged."
    fi
}

# -----------------------------
# Status / convenience commands
# -----------------------------

session-status() {
    local state="$(_oscp_state)"
    local engagement="${OSCP_ENGAGEMENT:-$(_oscp_read_active_engagement 2>/dev/null || true)}"

    print -r -- "Engagement: ${engagement:-none}"
    print -r -- "Mode      : ${OSCP_RECORDING_MODE:-none}"
    print -r -- "Target IP : ${IP:-none}"
    print -r -- "Directory : ${TARGET_PATH:-none}"
    if [[ -n "${IP:-}" ]]; then
        print -r -- "Working   : ${TARGET_PATH}/working"
    fi
    print -r -- "Session   : ${OSCP_SESSION_NAME:-none}"
    print -r -- "State     : $state"
    print -r -- "tun0      : $(_oscp_tun_ip)"

    if [[ "$state" == "LOG" ]]; then
        print -r -- "Cast      : ${OSCP_CAST_FILE:-unknown}"
        print -r -- "Text      : ${OSCP_TEXT_FILE:-generated/refreshed from cast}"
    else
        [[ -n "$OSCP_LAST_CAST" ]] && print -r -- "Last cast : $OSCP_LAST_CAST"
        [[ -n "$OSCP_LAST_TEXT" ]] && print -r -- "Last text : $OSCP_LAST_TEXT"
    fi
}

session-files() {
    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        print -r -- "Cast : ${OSCP_CAST_FILE:-unknown}"
        print -r -- "Text : ${OSCP_TEXT_FILE:-unknown}"
    else
        print -r -- "Cast : ${OSCP_LAST_CAST:-none}"
        print -r -- "Text : ${OSCP_LAST_TEXT:-none}"
    fi
}

session-play() {
    local f="${1:-${OSCP_LAST_CAST:-${OSCP_CAST_FILE:-}}}"

    [[ -n "$f" && -f "$f" ]] || {
        print -r -- "[-] No asciicast file supplied or available."
        return 1
    }

    command asciinema play "$f"
}

session-log() {
    local f="${1:-${OSCP_LAST_TEXT:-${OSCP_TEXT_FILE:-}}}"

    [[ -n "$f" && -f "$f" ]] || {
        print -r -- "[-] No searchable text log supplied or available."
        print -r -- "[=] If currently recording, run: refresh-log"
        return 1
    }

    command less -- "$f"
}

refresh-log() {
    local cast="${OSCP_CAST_FILE:-${OSCP_LAST_CAST:-}}"
    local outfile="${OSCP_TEXT_FILE:-${OSCP_LAST_TEXT:-}}"
    local tmp

    [[ -n "$cast" && -f "$cast" ]] || {
        print -r -- "[-] No asciicast file is available."
        return 1
    }

    [[ -n "$outfile" ]] || {
        print -r -- "[-] No text-log path is available."
        return 1
    }

    tmp="${outfile}.tmp.$$"

    if (umask 077; command asciinema convert -f txt "$cast" "$tmp"); then
        command mv -f -- "$tmp" "$outfile"
        command chmod 600 -- "$outfile" 2>/dev/null || true
        print -r -- "[+] Searchable log refreshed:"
        print -r -- "    $outfile"
    else
        command rm -f -- "$tmp"
        print -r -- "[-] Text conversion failed."
        print -r -- "[=] If the session is still active, try again after it ends."
        return 1
    fi
}

# -----------------------------
# On-Demand Setup & Recording
# -----------------------------

# Add engagement-specific workspace tabs to the current QTerminal window.
# QTerminal creates additional tabs through its D-Bus Window.newTab method.
setup() {
    if (( $# != 1 )) || [[ -z "${1:-}" ]]; then
        print -r -- "Usage: setup ENGAGEMENT"
        return 2
    fi

    local selected="$1" engagement_path service window_path helper scan_path qterminal_pid=""
    local reply pid parent_pid process_name paths spec label mode tab_workdir tab_args

    selected="$(_oscp_resolve_engagement_name "$selected")" || return 1
    engagement_path="$OSCP_BASE_DIR/$selected"

    if [[ -d "$engagement_path" ]]; then
        print -r -- "[!] Engagement directory already exists; reusing: $engagement_path"
    elif [[ -e "$engagement_path" || -L "$engagement_path" ]]; then
        print -r -- "[-] Engagement path exists but is not a directory: $engagement_path"
        return 1
    fi

    print -Pn "%F{cyan}[?]%f Open QTerminal workspace for engagement %F{green}${selected}%f? %F{white}[y/N]%f: "
    if ! read -rq; then
        print "\n[=] Aborted."
        return 0
    fi
    print

    command -v gdbus >/dev/null 2>&1 || { print -r -- "[-] gdbus is not installed."; return 1; }
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || {
        print -r -- "[-] No desktop D-Bus session is available. Run setup inside your QTerminal desktop session."
        return 1
    }
    helper="$HOME/.config/oscp/tab-bootstrap.sh"
    [[ -x "$helper" ]] || { print -r -- "[-] QTerminal tab helper is missing. Reinstall oscp-setup.sh."; return 1; }

    # Find the QTerminal process that owns this shell, including recorded shells.
    pid=$$
    while (( pid > 1 )); do
        process_name="$(command ps -p "$pid" -o comm= 2>/dev/null | command tr -d '[:space:]')"
        case "$process_name" in
            qterminal|qterminal.real) qterminal_pid="$pid"; break ;;
        esac
        parent_pid="$(command ps -p "$pid" -o ppid= 2>/dev/null | command tr -d '[:space:]')"
        [[ "$parent_pid" =~ ^[0-9]+$ && "$parent_pid" != "$pid" ]] || break
        pid="$parent_pid"
    done
    [[ -n "$qterminal_pid" ]] || {
        print -r -- "[-] This shell is not running inside QTerminal. Open QTerminal and run setup there."
        return 1
    }

    service="org.lxqt.QTerminal-${qterminal_pid}"
    reply="$(command gdbus call --session --dest "$service" --object-path / --method org.lxqt.QTerminal.Process.getActiveWindow 2>/dev/null)" || {
        print -r -- "[-] Could not contact this QTerminal process on D-Bus."
        return 1
    }
    window_path="$(print -r -- "$reply" | command grep -oE '/windows/[[:alnum:]_]+' | command head -n1 || true)"
    if [[ -z "$window_path" ]]; then
        # An unfocused process is safe to use only if it has a single window.
        reply="$(command gdbus call --session --dest "$service" --object-path / --method org.lxqt.QTerminal.Process.getWindows 2>/dev/null)" || reply=""
        paths="$(print -r -- "$reply" | command grep -oE '/windows/[[:alnum:]_]+' || true)"
        [[ -n "$paths" && "$paths" != *$'\n'* ]] && window_path="$paths"
    fi
    [[ -n "$window_path" ]] || {
        print -r -- "[-] Could not identify the current QTerminal window. Keep it focused and try again."
        return 1
    }

    _oscp_set_active_engagement "$selected" || return 1
    _oscp_initialize_engagement || return 1
    scan_path="$OSCP_ENGAGEMENT_PATH/scans"
    command mkdir -p -- "$HOME/Transfer" || return 1
    if [[ "$HOME" == *"'"* || "$OSCP_ENGAGEMENT_PATH" == *"'"* ]]; then
        print -r -- "[-] QTerminal tab paths cannot contain a single quote."
        return 1
    fi

    for spec in \
        Scanning_1:scan Scanning_2:scan Working_1:log Working_2:log Target:idle \
        HTTP_Server:http NC_1:idle NC_2:idle Ligolo:log \
        Wireshark:log Responder:log; do
        label="${spec%%:*}"
        mode="${spec#*:}"
        tab_workdir="$OSCP_ENGAGEMENT_PATH"
        [[ "$mode" == "scan" ]] && tab_workdir="$scan_path"
        [[ "$mode" == "http" ]] && tab_workdir="$HOME/Transfer"
        tab_args="{'workingDirectory': <'$tab_workdir'>, 'shell': <['$helper', '$selected', '$label', '$mode', '$OSCP_BASE_DIR']>}"

        if ! command gdbus call --session --dest "$service" --object-path "$window_path" \
            --method org.lxqt.QTerminal.Window.newTab "$tab_args" >/dev/null 2>&1; then
            print -r -- "[-] Could not open the $label tab. Tabs opened so far remain available."
            return 1
        fi
    done

    print -r -- "[+] QTerminal workspace ready for $OSCP_ENGAGEMENT"
    print -r -- "[=] Scanning tabs: scans/ with scanme"
    print -r -- "[=] Work and tool tabs: logme records in general-log/"
    print -r -- "[=] Target and NC tabs: engagement root without logging"
    print -r -- "[=] HTTP_Server: ~/Transfer with a general-log/ recording"
}

logme() {
    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        print -P "%F{yellow}[=] This terminal is already being recorded.%f"
        session-status
        return 0
    fi

    local engagement_arg="${1:-}" working_dir log_dir previous_ip="${IP:-}" previous_target_path="${TARGET_PATH:-}"
    local previous_mode="${OSCP_RECORDING_MODE:-}" previous_session_name="${OSCP_SESSION_NAME:-}"
    local stamp prefix rc=0

    _oscp_select_engagement "$engagement_arg" || return 1
    log_dir="$OSCP_ENGAGEMENT_PATH/general-log"
    working_dir="$OSCP_ENGAGEMENT_PATH"
    if [[ "${OSCP_TAB_BOOTSTRAP_MODE:-}" == "http" ]]; then
        working_dir="${OSCP_TAB_BOOTSTRAP_WORKDIR:-$HOME/Transfer}"
    fi

    if [[ "${OSCP_TAB_BOOTSTRAP_MODE:-}" != "log" && "${OSCP_TAB_BOOTSTRAP_MODE:-}" != "http" ]]; then
        print -Pn "%F{cyan}[?]%f Start general logging in %F{green}${log_dir}%f? %F{white}[y/N]%f: "
        if ! read -rq; then
            print "\n[=] Aborted."
            return 0
        fi
        print
    fi

    _oscp_initialize_engagement || return 1
    [[ -d "$working_dir" ]] || (umask 077; command mkdir -p -- "$working_dir")

    _oscp_prompt_session_title
    OSCP_RECORDING_MODE="log"
    IP=""
    TARGET_PATH="$working_dir"

    stamp="$(_oscp_stamp)"
    prefix="log_${stamp}_${OSCP_SESSION_NAME}_T$$"
    OSCP_CAST_FILE="$log_dir/${prefix}.cast"
    OSCP_TEXT_FILE="$log_dir/${prefix}.log"

    builtin cd -- "$working_dir" || return 1

    export IP TARGET_PATH OSCP_RECORDING_MODE OSCP_SESSION_NAME OSCP_CAST_FILE OSCP_TEXT_FILE

    (umask 077; command asciinema rec --quiet "$OSCP_CAST_FILE") || rc=$?

    if [[ -f "$OSCP_CAST_FILE" ]]; then
        command chmod 600 -- "$OSCP_CAST_FILE" 2>/dev/null || true

        if (umask 077; command asciinema convert -f txt "$OSCP_CAST_FILE" "$OSCP_TEXT_FILE"); then
            command chmod 600 -- "$OSCP_TEXT_FILE" 2>/dev/null || true
        else
            print -r -- "[!] Recording saved, but searchable text conversion failed."
        fi
    fi

    OSCP_LAST_CAST="$OSCP_CAST_FILE"
    OSCP_LAST_TEXT="$OSCP_TEXT_FILE"

    unset OSCP_CAST_FILE
    unset OSCP_TEXT_FILE

    IP="$previous_ip"
    TARGET_PATH="$previous_target_path"
    OSCP_RECORDING_MODE="$previous_mode"
    OSCP_SESSION_NAME="$previous_session_name"
    export IP TARGET_PATH OSCP_RECORDING_MODE OSCP_SESSION_NAME

    # Keep the shell in its working directory after recording ends.
    builtin cd -- "$working_dir" || return 1

    print
    print -P "%F{yellow}[=] Recording ended.%f"
    print -r -- "[=] Replay     : $OSCP_LAST_CAST"
    print -r -- "[=] Searchable : $OSCP_LAST_TEXT"
    print

    return "$rc"
}

scanme() {
    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        print -P "%F{yellow}[=] This terminal is already being recorded.%f"
        session-status
        return 0
    fi

    local engagement_arg="${1:-}" stamp prefix scan_path targets_file rc=0

    _oscp_select_engagement "$engagement_arg" || return 1
    scan_path="$OSCP_ENGAGEMENT_PATH/scans"
    targets_file="$OSCP_ENGAGEMENT_PATH/targets.txt"

    if [[ "${OSCP_TAB_BOOTSTRAP_MODE:-}" != "scan" ]]; then
        print -Pn "%F{cyan}[?]%f Start scan logging in %F{green}${scan_path}%f? %F{white}[y/N]%f: "
        if ! read -rq; then
            print "\n[=] Aborted."
            return 0
        fi
        print
    fi

    _oscp_initialize_engagement || return 1
    _oscp_prompt_session_title

    IP=""
    TARGET_PATH="$scan_path"
    OSCP_RECORDING_MODE="scan"
    builtin cd -- "$scan_path" || return 1

    stamp="$(_oscp_stamp)"
    prefix="scan_${stamp}_${OSCP_SESSION_NAME}_T$$"
    OSCP_CAST_FILE="$scan_path/${prefix}.cast"
    OSCP_TEXT_FILE="$scan_path/${prefix}.log"

    export IP TARGET_PATH OSCP_RECORDING_MODE OSCP_ENGAGEMENT OSCP_ENGAGEMENT_PATH OSCP_SESSION_NAME OSCP_CAST_FILE OSCP_TEXT_FILE

    (umask 077; command asciinema rec --quiet "$OSCP_CAST_FILE") || rc=$?

    if [[ -f "$OSCP_CAST_FILE" ]]; then
        command chmod 600 -- "$OSCP_CAST_FILE" 2>/dev/null || true

        if (umask 077; command asciinema convert -f txt "$OSCP_CAST_FILE" "$OSCP_TEXT_FILE"); then
            command chmod 600 -- "$OSCP_TEXT_FILE" 2>/dev/null || true
        else
            print -r -- "[!] Recording saved, but searchable text conversion failed."
        fi
    fi

    OSCP_LAST_CAST="$OSCP_CAST_FILE"
    OSCP_LAST_TEXT="$OSCP_TEXT_FILE"

    unset OSCP_CAST_FILE
    unset OSCP_TEXT_FILE

    # Keep the shell in the scan workspace after initial-scan logging ends.
    builtin cd -- "$scan_path" || return 1

    print
    print -P "%F{yellow}[=] Recording ended.%f"
    print -r -- "[=] Replay     : $OSCP_LAST_CAST"
    print -r -- "[=] Searchable : $OSCP_LAST_TEXT"
    print -r -- "[=] Start target logging: scriptme"
    print

    return "$rc"
}

scriptme() {
    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        print -P "%F{yellow}[=] This terminal is already being recorded.%f"
        session-status
        return 0
    fi

    local engagement_arg="${1:-}" target_ip target_ip_slug target_path key stamp prefix targets_file rc=0

    # 1. Select or remember the active engagement.
    _oscp_select_engagement "$engagement_arg" || return 1

    # 2. Target IP prompt & confirmation loop.
    while true; do
        print -Pn "%F{cyan}[?]%f Enter target IP address: "
        read -r target_ip

        if [[ -z "$target_ip" ]]; then
            print -P "%F{yellow}[!] Target IP cannot be empty.%f"
            continue
        fi

        print -Pn "%F{cyan}[?]%f Confirm target %F{green}${target_ip}%f? %F{white}[Y/n]%f: "
        read -rk 1 key
        [[ "$key" != $'\n' ]] && print

        if [[ -z "$key" || "$key" == $'\n' || "$key" =~ ^[Yy]$ ]]; then
            break
        else
            print -P "%F{yellow}[!] Restarting IP entry...%f"
        fi
    done

    # 3. Resolve the confirmed target path, then confirm logging there.
    target_ip_slug="$(_oscp_slug "$target_ip")"
    target_path="$OSCP_ENGAGEMENT_PATH/$target_ip_slug"

    print -Pn "%F{cyan}[?]%f Start target logging in %F{green}${target_path}%f? %F{white}[y/N]%f: "
    if ! read -rq; then
        print "\n[=] Aborted."
        return 0
    fi
    print

    # 4. Enter the session title after logging is confirmed.
    targets_file="$OSCP_ENGAGEMENT_PATH/targets.txt"

    IP="$target_ip_slug"
    TARGET_PATH="$target_path"
    _oscp_prompt_session_title

    # 5. Create the engagement directory, targets.txt, and target subdirectories/files.

    # Initialize engagement-level scans/, credentials/, and targets.txt.
    _oscp_initialize_engagement || return 1

    # Create target-specific evidence and working directories.
    # working/ is for nonstandard exploit files and transfer items.
    (umask 077; command mkdir -p -- \
        "$TARGET_PATH" \
        "$TARGET_PATH/working" \
        "$TARGET_PATH/screenshots" \
        "$TARGET_PATH/web-documents" \
        "$TARGET_PATH/loot") || return 1
    command chmod 700 -- \
        "$TARGET_PATH" \
        "$TARGET_PATH/working" \
        "$TARGET_PATH/screenshots" \
        "$TARGET_PATH/web-documents" \
        "$TARGET_PATH/loot" 2>/dev/null || true
    # Record the target IP once in the engagement-level target list.
    if ! command grep -Fqx "$IP" "$targets_file" 2>/dev/null; then
        print -r -- "$IP" >> "$targets_file"
    fi
    builtin cd -- "$TARGET_PATH" || return 1

    # 6. Nest the log files directly inside the target directory
    stamp="$(_oscp_stamp)"
    prefix="terminal_${stamp}_${OSCP_SESSION_NAME}_T$$"

    OSCP_CAST_FILE="$TARGET_PATH/${prefix}.cast"
    OSCP_TEXT_FILE="$TARGET_PATH/${prefix}.log"

    OSCP_RECORDING_MODE="target"
    export IP TARGET_PATH OSCP_RECORDING_MODE OSCP_ENGAGEMENT OSCP_ENGAGEMENT_PATH OSCP_SESSION_NAME OSCP_CAST_FILE OSCP_TEXT_FILE

    # 7. Start asciinema recording
    (umask 077; command asciinema rec --quiet "$OSCP_CAST_FILE") || rc=$?

    # 8. Convert .cast to searchable .log automatically on exit
    if [[ -f "$OSCP_CAST_FILE" ]]; then
        command chmod 600 -- "$OSCP_CAST_FILE" 2>/dev/null || true

        if (umask 077; command asciinema convert -f txt "$OSCP_CAST_FILE" "$OSCP_TEXT_FILE"); then
            command chmod 600 -- "$OSCP_TEXT_FILE" 2>/dev/null || true
        else
            print -r -- "[!] Recording saved, but searchable text conversion failed."
        fi
    fi

    OSCP_LAST_CAST="$OSCP_CAST_FILE"
    OSCP_LAST_TEXT="$OSCP_TEXT_FILE"

    unset OSCP_CAST_FILE
    unset OSCP_TEXT_FILE

    # Keep the shell in the selected target directory after target logging ends.
    builtin cd -- "$TARGET_PATH" || return 1

    print
    print -P "%F{yellow}[=] Recording ended.%f"
    print -r -- "[=] Replay     : $OSCP_LAST_CAST"
    print -r -- "[=] Searchable : $OSCP_LAST_TEXT"
    print -r -- "[=] Start another: scriptme"
    print

    return "$rc"
}

# Alias start-log to scriptme so old muscle memory still works
alias start-log='scriptme'

stop-log() {
    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        builtin exit
    else
        print -r -- "[=] Logging is already stopped."
    fi
}

# -----------------------------
# Child-Shell Initialization
# -----------------------------

_oscp_child_init() {
    # Only runs inside the recorded asciinema child shell
    if [[ -n "${ASCIINEMA_SESSION:-}" ]]; then
        [[ -n "${TARGET_PATH:-}" && -d "$TARGET_PATH" ]] && builtin cd -- "$TARGET_PATH"
        print
        print -P "%F{green}[+] Recording active:%f ${OSCP_SESSION_NAME:-$IP}"
        print -r -- "[=] Engagement: ${OSCP_ENGAGEMENT:-none}"
        if [[ -n "${IP:-}" ]]; then
            print -r -- "[=] Target IP : $IP (exported as \$IP)"
        elif [[ "${OSCP_RECORDING_MODE:-}" == "log" ]]; then
            print -r -- "[=] Target IP : none (general log)"
        else
            print -r -- "[=] Target IP : none (initial discovery)"
        fi
        print -r -- "[=] Directory : $(pwd)"
        [[ -n "${IP:-}" ]] && print -r -- "[=] Working   : ${TARGET_PATH}/working"
        print -r -- "[=] Cast      : ${OSCP_CAST_FILE:-unknown}"
        print -r -- "[=] Text      : ${OSCP_TEXT_FILE:-unknown} (generated on exit)"
        print -r -- "[=] Stop      : exit, Ctrl+D, or stop-log"
        _oscp_show_tips
    fi
}

_oscp_tab_bootstrap() {
    local mode="${OSCP_TAB_BOOTSTRAP_MODE:-}"
    [[ -n "$mode" && -z "${ASCIINEMA_SESSION:-}" ]] || return 0

    case "$mode" in
        scan) scanme "$OSCP_ENGAGEMENT" ;;
        log|http) logme "$OSCP_ENGAGEMENT" ;;
        idle)
            _oscp_set_active_engagement "$OSCP_ENGAGEMENT" || return 1
            _oscp_initialize_engagement || return 1
            builtin cd -- "$OSCP_ENGAGEMENT_PATH" || return 1
            ;;
        *) print -r -- "[-] Unknown QTerminal tab mode: $mode" ;;
    esac

    unset OSCP_TAB_BOOTSTRAP_MODE OSCP_TAB_BOOTSTRAP_WORKDIR
    return 0
}

_oscp_shell_title_init
_oscp_child_init
_oscp_tab_bootstrap
ZSH

    cat > "$TAB_BOOTSTRAP_FILE" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail

if (( $# != 4 )); then
    printf 'Usage: %s ENGAGEMENT TAB_NAME scan|log|http|idle BASE_DIR\n' "$0" >&2
    exit 2
fi

engagement="$1"
tab_name="$2"
mode="$3"
base_dir="$4"
case "$engagement" in ''|*[!A-Za-z0-9._-]*) printf 'Invalid engagement name.\n' >&2; exit 2;; esac
case "$tab_name" in ''|*[!A-Za-z0-9._-]*) printf 'Invalid tab name.\n' >&2; exit 2;; esac
case "$mode" in scan|log|http|idle) ;; *) printf 'Invalid tab mode.\n' >&2; exit 2;; esac
[[ -n "$base_dir" && -d "$base_dir" ]] || { printf 'Invalid engagement base directory.\n' >&2; exit 2; }

export OSCP_BASE_DIR="$base_dir"
export OSCP_ENGAGEMENT="$engagement"
export OSCP_ENGAGEMENT_PATH="$OSCP_BASE_DIR/$engagement"
export OSCP_SESSION_NAME="$tab_name"
export OSCP_SHELL_TITLE="$tab_name"
export OSCP_TAB_BOOTSTRAP_MODE="$mode"
unset ASCIINEMA_SESSION IP TARGET_PATH OSCP_RECORDING_MODE
unset OSCP_CAST_FILE OSCP_TEXT_FILE OSCP_LAST_CAST OSCP_LAST_TEXT
unset OSCP_TAB_BOOTSTRAP_WORKDIR

workdir="$OSCP_ENGAGEMENT_PATH"
if [[ "$mode" == scan ]]; then
    workdir="$OSCP_ENGAGEMENT_PATH/scans"
elif [[ "$mode" == http ]]; then
    workdir="$HOME/Transfer"
    export OSCP_TAB_BOOTSTRAP_WORKDIR="$workdir"
fi

cd -- "$workdir"
exec zsh -i
BOOTSTRAP
    chmod 700 "$TAB_BOOTSTRAP_FILE"

    if ! grep -Fqx "$SOURCE_LINE" "$ZSHRC"; then
        printf '\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
        info "Added logger loader to ~/.zshrc"
    else
        note "Logger loader already present in ~/.zshrc"
    fi

    info "Installed OSCP on-demand logger: $CONFIG_FILE"
    note "Base directory configured as: ${OSCP_BASE_DIR:-$HOME/oscp-test}"
    note "Active engagement is remembered in: ${OSCP_BASE_DIR:-$HOME/oscp-test}/.active-engagement"
    note "Open a new terminal (or run 'source ~/.zshrc'), then run: setup NAME, logme, scanme, or scriptme"
}

uninstall_logger() {
    local stamp current_copy archived_backup

    stamp="$(date -u '+%Y%m%d_%H%M%S_UTC')"
    current_copy="$HOME/.zshrc_oscp_before_uninstall_$stamp"

    if [[ -e "$ZSHRC" ]]; then
        cp -a "$ZSHRC" "$current_copy"
        info "Saved current ~/.zshrc to: $current_copy"
    fi

    if [[ -e "$ZSHRC" ]] && grep -Fqx "$SOURCE_LINE" "$ZSHRC"; then
        grep -Fvx "$SOURCE_LINE" "$ZSHRC" > "${ZSHRC}.tmp" || true
        chmod --reference="$ZSHRC" "${ZSHRC}.tmp"
        mv "${ZSHRC}.tmp" "$ZSHRC"
        note "Removed logger loader from ~/.zshrc; other changes were preserved."
    fi

    if [[ -e "$BACKUP" ]]; then
        archived_backup="${BACKUP}.archived_${stamp}_$$"
        mv "$BACKUP" "$archived_backup"
        note "Archived first-install ~/.zshrc backup as: $archived_backup"
    fi

    rm -f "$CONFIG_FILE" "$TAB_BOOTSTRAP_FILE"
    rmdir "$CONFIG_DIR" 2>/dev/null || true

    info "Removed logger configuration."
    note "Existing files under ${OSCP_BASE_DIR:-$HOME/oscp-test} were preserved."
}

case "$ACTION" in
    help|--help|-h)
        printf 'Usage: %s [install|uninstall|help]\n' "$0"
        printf 'No argument runs install. Installation adds a loader to ~/.zshrc.\n'
        ;;
    install|--install|-i)
        install_logger
        ;;
    uninstall|--uninstall|-u)
        uninstall_logger
        ;;
    *)
        printf 'Usage: %s [install|uninstall|help]\n' "$0" >&2
        exit 2
        ;;
esac
