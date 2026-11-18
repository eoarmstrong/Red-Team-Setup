#!/usr/bin/env bash
# Exercise installation only inside a disposable HOME in this tests directory.
set -euo pipefail

tests_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source_file="$(cd -- "$tests_dir/.." && pwd -P)/oscp-setup.sh"
[[ -f "$source_file" ]] || { printf 'Missing oscp-setup.sh\n' >&2; exit 1; }

smoke_home="$(mktemp -d "$tests_dir/.smoke.XXXXXXXX")"
cleanup() {
    local parent name
    parent="$(cd -- "$(dirname -- "$smoke_home")" && pwd -P)" || return
    name="$(basename -- "$smoke_home")"
    if [[ "$parent" == "$tests_dir" && "$name" == .smoke.* && -d "$smoke_home" && ! -L "$smoke_home" ]]; then
        rm -rf -- "$smoke_home"
    else
        printf 'Left test directory in place because its path failed cleanup validation: %s\n' "$smoke_home" >&2
    fi
}
trap cleanup EXIT

export HOME="$smoke_home"
unset OSCP_BASE_DIR
mkdir -p -- "$HOME/bin"
cat > "$HOME/bin/asciinema" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
    printf 'asciinema 3.0.0\n'
else
    printf 'asciinema stub: only --version is supported\n' >&2
    exit 1
fi
STUB
chmod 700 "$HOME/bin/asciinema"
export PATH="$HOME/bin:$PATH"

fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$*"; }

zshrc="$HOME/.zshrc"
backup="$HOME/.zshrc_oscp_backup"
config="$HOME/.config/oscp/asciinema-logger.zsh"
helper="$HOME/.config/oscp/tab-bootstrap.sh"
loader='[[ -f "$HOME/.config/oscp/asciinema-logger.zsh" ]] && source "$HOME/.config/oscp/asciinema-logger.zsh"'

printf '%s\n' '# original user setting' > "$zshrc"
bash -n "$source_file"
bash "$source_file" install >/dev/null
[[ -f "$backup" && -f "$config" && -x "$helper" ]] || fail 'Install did not create the expected files.'
bash -n "$helper" || fail 'Generated tab helper has invalid Bash syntax.'
grep -Fqx '# original user setting' "$backup" || fail 'Original .zshrc backup was changed.'
[[ "$(grep -Fxc "$loader" "$zshrc" || true)" == 1 ]] || fail 'Loader was not added exactly once.'
grep -Fq 'typeset -g OSCP_BASE_DIR="${OSCP_BASE_DIR:-$HOME/oscp-test}"' "$config" || fail 'Generated config does not default to HOME/oscp-test.'
! grep -Fq '/home/kali/oscp-test' "$config" || fail 'Generated config contains a fixed Kali home path.'
grep -Fq 'export OSCP_BASE_DIR="$base_dir"' "$helper" || fail 'Tab helper does not use the selected base directory.'
pass 'First install, original backup, loader, and portable HOME default.'

printf '%s\n' '# smoke custom logger' >> "$config"
printf '%s\n' '# smoke custom helper' >> "$helper"
bash "$source_file" install >/dev/null
[[ "$(grep -Fxc "$loader" "$zshrc" || true)" == 1 ]] || fail 'Reinstall duplicated the loader.'
shopt -s nullglob
logger_backups=("$config".before-install_*)
helper_backups=("$helper".before-install_*)
(( ${#logger_backups[@]} > 0 && ${#helper_backups[@]} > 0 )) || fail 'Reinstall did not back up generated files.'
grep -Fqx '# smoke custom logger' "${logger_backups[0]}" || fail 'Logger reinstall backup lost the prior content.'
grep -Fqx '# smoke custom helper' "${helper_backups[0]}" || fail 'Helper reinstall backup lost the prior content.'
pass 'Reinstall keeps one loader and backs up both generated files.'

printf '%s\n' '# user setting added later' >> "$zshrc"
bash "$source_file" uninstall >/dev/null
grep -Fqx '# original user setting' "$zshrc" || fail 'Uninstall lost the original .zshrc line.'
grep -Fqx '# user setting added later' "$zshrc" || fail 'Uninstall lost the later .zshrc line.'
! grep -Fqx "$loader" "$zshrc" || fail 'Uninstall left the loader in .zshrc.'
[[ ! -e "$config" && ! -e "$helper" ]] || fail 'Uninstall left generated files active.'
pass 'Uninstall removes integration and preserves later user edits.'
