#!/bin/bash

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  SSH Onboarding Bootstrap  v5.0                                            ║
# ║  Run once on a new machine. Installs gh, authenticates, clones repo,       ║
# ║  sources environment script. Curl-pipeable.                                ║
# ╚════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

ONBOARD_VERSION="5.0.0"
GITHUB_REPO="ryanhebert/personal_scripts"
REPO_DIR="$HOME/personal_scripts"
SCRIPTS_DIR="$REPO_DIR/scripts"
ENV_SCRIPT="$SCRIPTS_DIR/environment.sh"
SOURCE_LINE="source \"$ENV_SCRIPT\"  # [ONBOARD]"
MARKER="# [ONBOARD]"
OLD_MARKER="# [SSH ONBOARDING]"

# ── Colors & Symbols ─────────────────────────────────────────────────────────

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_GREEN="\033[38;5;114m"
C_BLUE="\033[38;5;75m"
C_YELLOW="\033[38;5;221m"
C_RED="\033[38;5;203m"
C_CYAN="\033[38;5;117m"
C_GRAY="\033[38;5;245m"
C_WHITE="\033[38;5;255m"
C_MAGENTA="\033[38;5;176m"
C_ORANGE="\033[38;5;209m"

SYM_CHECK="✔"
SYM_CROSS="✖"
SYM_ARROW="▶"
SYM_GEAR="⚙"
SYM_SCREEN="◉"
SYM_DOTS="···"
SYM_LINE="─"
SYM_WARN="⚠"

# ── UI Helpers ────────────────────────────────────────────────────────────────

_hr() {
    local width=62 line=""
    for ((i = 0; i < width; i++)); do line+="$SYM_LINE"; done
    echo -e "${C_GRAY}${line}${C_RESET}"
}

_banner() {
    echo ""
    _hr
    echo -e "${C_BOLD}${C_BLUE}  ${SYM_SCREEN}  SSH Onboarding Bootstrap${C_RESET}  ${C_DIM}v${ONBOARD_VERSION}${C_RESET}"
    echo -e "${C_GRAY}     One-time setup for new machines${C_RESET}"
    _hr
}

_step() {
    local symbol="$1" color="$2" message="$3"
    echo -e "  ${color}${symbol}${C_RESET}  ${C_WHITE}${message}${C_RESET}"
}

_step_ok()   { _step "$SYM_CHECK" "$C_GREEN"   "$1"; }
_step_warn() { _step "$SYM_WARN"  "$C_YELLOW"  "$1"; }
_step_fail() { _step "$SYM_CROSS" "$C_RED"     "$1"; }
_step_info() { _step "$SYM_GEAR"  "$C_CYAN"    "$1"; }
_step_dim()  { _step "$SYM_DOTS"  "$C_GRAY"    "$1"; }

# ── Shell RC Detection ───────────────────────────────────────────────────────

_detect_rc_file() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "$HOME/.bash_profile"
    else
        echo "$HOME/.bashrc"
    fi
}

# ── Step 1: Install gh CLI ───────────────────────────────────────────────────

_install_gh() {
    if command -v gh &>/dev/null; then
        _step_ok "GitHub CLI already installed ${C_DIM}($(gh --version | head -1 | awk '{print $3}'))${C_RESET}"
        return 0
    fi

    _step_info "Installing GitHub CLI${SYM_DOTS}"

    if command -v apt-get &>/dev/null; then
        # Add GitHub's official apt repo
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq && sudo apt-get install -y -qq gh
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q gh
    elif command -v yum &>/dev/null; then
        sudo yum install -y -q gh
    elif command -v brew &>/dev/null; then
        brew install gh
    else
        _step_fail "No supported package manager found (apt/dnf/yum/brew)"
        _step_dim  "Install gh manually: https://cli.github.com/"
        return 1
    fi

    if command -v gh &>/dev/null; then
        _step_ok "GitHub CLI installed ${C_DIM}($(gh --version | head -1 | awk '{print $3}'))${C_RESET}"
    else
        _step_fail "Failed to install GitHub CLI"
        return 1
    fi
}

# ── Step 2: Install qrencode ─────────────────────────────────────────────────

_install_qrencode() {
    if command -v qrencode &>/dev/null; then
        _step_ok "qrencode already installed"
        return 0
    fi

    _step_info "Installing qrencode${SYM_DOTS}"

    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y -qq qrencode
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y -q qrencode
    elif command -v yum &>/dev/null; then
        sudo yum install -y -q qrencode
    elif command -v brew &>/dev/null; then
        brew install qrencode
    else
        _step_warn "Could not install qrencode — QR code display will be skipped"
        return 0
    fi

    if command -v qrencode &>/dev/null; then
        _step_ok "qrencode installed"
    else
        _step_warn "qrencode installation failed — QR code display will be skipped"
    fi
}

# ── Step 3: Authenticate with GitHub ─────────────────────────────────────────

_authenticate() {
    if gh auth status &>/dev/null; then
        local user
        user=$(gh api user --jq '.login' 2>/dev/null || echo "authenticated")
        _step_ok "GitHub authenticated ${C_DIM}(${user})${C_RESET}"
        return 0
    fi

    _step_info "GitHub authentication required"
    echo ""

    # Show QR code for the device flow URL
    if command -v qrencode &>/dev/null; then
        echo -e "  ${C_DIM}Scan to open GitHub device activation:${C_RESET}"
        echo ""
        qrencode -t ansiutf8 "https://github.com/login/device" 2>/dev/null | sed 's/^/    /'
        echo ""
    else
        echo -e "  ${C_CYAN}Open:${C_RESET} https://github.com/login/device"
        echo ""
    fi

    # gh auth login handles the device flow: shows code, polls, stores token
    if gh auth login --web -p https -s repo; then
        echo ""
        _step_ok "GitHub authentication successful"
    else
        echo ""
        _step_fail "GitHub authentication failed"
        _step_dim  "You can retry later with: $0"
        return 1
    fi
}

# ── Step 4: Clone repo ───────────────────────────────────────────────────────

_clone_repo() {
    if [[ -d "$REPO_DIR/.git" ]]; then
        _step_ok "Repository already cloned ${C_DIM}(${REPO_DIR})${C_RESET}"
        return 0
    fi

    _step_info "Cloning ${GITHUB_REPO}${SYM_DOTS}"

    if gh repo clone "$GITHUB_REPO" "$REPO_DIR"; then
        _step_ok "Repository cloned to ${C_CYAN}${REPO_DIR}${C_RESET}"
    else
        _step_fail "Failed to clone repository"
        return 1
    fi
}

# ── Step 5: Install source line in shell RC ──────────────────────────────────

_install_source_line() {
    local rc_file
    rc_file=$(_detect_rc_file)

    # Check if already installed with current marker
    if [[ -f "$rc_file" ]] && grep -qF "$MARKER" "$rc_file"; then
        # Verify it points to the right script
        if grep -qF "$ENV_SCRIPT" "$rc_file"; then
            _step_ok "Source line already in ${C_DIM}$(basename "$rc_file")${C_RESET}"
            return 0
        else
            # Update the source path
            local tmp_file
            tmp_file=$(mktemp)
            grep -v "$MARKER" "$rc_file" > "$tmp_file"
            echo "$SOURCE_LINE" >> "$tmp_file"
            mv "$tmp_file" "$rc_file"
            _step_ok "Updated source line in ${C_DIM}$(basename "$rc_file")${C_RESET}"
            return 0
        fi
    fi

    # Append source line
    echo "" >> "$rc_file"
    echo "$SOURCE_LINE" >> "$rc_file"
    _step_ok "Added source line to ${C_DIM}$(basename "$rc_file")${C_RESET}"
}

# ── Script Discovery ─────────────────────────────────────────────────────────

_discover_scripts() {
    # Find .sh files in scripts/ and parse their Description headers
    local script_files=()
    local script_descs=()

    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        return 1
    fi

    while IFS= read -r -d '' file; do
        local desc
        desc=$(grep -m1 '^# Description:' "$file" 2>/dev/null | sed 's/^# Description:[[:space:]]*//')
        if [[ -z "$desc" ]]; then
            desc="(no description)"
        fi
        script_files+=("$file")
        script_descs+=("$desc")
    done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name "*.sh" -print0 | sort -z)

    if [[ ${#script_files[@]} -eq 0 ]]; then
        return 1
    fi

    # Export for menu use
    _SCRIPT_FILES=("${script_files[@]}")
    _SCRIPT_DESCS=("${script_descs[@]}")
}

_show_menu() {
    if ! _discover_scripts; then
        _step_warn "No scripts found in ${SCRIPTS_DIR}"
        return 1
    fi

    echo ""
    echo -e "  ${C_BOLD}${C_WHITE}Available scripts:${C_RESET}"
    echo ""

    local env_index=-1
    for i in "${!_SCRIPT_FILES[@]}"; do
        local basename_sh
        basename_sh=$(basename "${_SCRIPT_FILES[$i]}")
        local marker=""
        if [[ "$basename_sh" == "environment.sh" ]]; then
            marker=" ${C_GREEN}(recommended)${C_RESET}"
            env_index=$i
        fi
        printf "  ${C_CYAN}%2d${C_RESET}  %-24s ${C_DIM}%s${C_RESET}%b\n" \
            "$((i + 1))" "$basename_sh" "${_SCRIPT_DESCS[$i]}" "$marker"
    done

    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Select script to source [1-%d]: ${C_RESET}" "${#_SCRIPT_FILES[@]}"
    read -r choice

    if [[ -z "$choice" && "$env_index" -ge 0 ]]; then
        choice=$((env_index + 1))
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#_SCRIPT_FILES[@]} )); then
        local selected="${_SCRIPT_FILES[$((choice - 1))]}"
        local selected_name
        selected_name=$(basename "$selected")
        local rc_file
        rc_file=$(_detect_rc_file)

        # Update source line to point to selected script
        local new_source_line="source \"${selected}\"  $MARKER"

        if [[ -f "$rc_file" ]] && grep -qF "$MARKER" "$rc_file"; then
            local tmp_file
            tmp_file=$(mktemp)
            grep -v "$MARKER" "$rc_file" > "$tmp_file"
            echo "$new_source_line" >> "$tmp_file"
            mv "$tmp_file" "$rc_file"
        else
            echo "" >> "$rc_file"
            echo "$new_source_line" >> "$rc_file"
        fi

        _step_ok "Configured ${C_CYAN}${selected_name}${C_RESET} in $(basename "$rc_file")"
    else
        _step_warn "Invalid selection"
        return 1
    fi
}

# ── Update ────────────────────────────────────────────────────────────────────

_do_update() {
    if [[ ! -d "$REPO_DIR/.git" ]]; then
        _step_fail "Repository not found at ${REPO_DIR}"
        _step_dim  "Run $0 first to bootstrap"
        return 1
    fi

    _step_info "Checking for updates${SYM_DOTS}"

    local before after
    before=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)

    if git -C "$REPO_DIR" pull --ff-only 2>/dev/null; then
        after=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null)
        if [[ "$before" == "$after" ]]; then
            _step_ok "Already up to date"
        else
            _step_ok "Updated ${C_DIM}(${before:0:7} → ${after:0:7})${C_RESET}"
            echo ""
            _step_dim "Changed files:"
            git -C "$REPO_DIR" diff --name-only "${before}..${after}" 2>/dev/null | while read -r f; do
                _step_dim "  ${f}"
            done
        fi
    else
        _step_fail "Update failed — you may have local changes"
        _step_dim  "Try: cd ${REPO_DIR} && git status"
        return 1
    fi
}

# ── Status ────────────────────────────────────────────────────────────────────

_show_status() {
    _banner
    echo ""

    # Auth status
    echo -e "  ${C_BOLD}Authentication${C_RESET}"
    if gh auth status &>/dev/null; then
        local user
        user=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
        _step_ok "Logged in as ${C_CYAN}${user}${C_RESET}"
    else
        _step_warn "Not authenticated"
        _step_dim  "Run: $0"
    fi
    echo ""

    # Repo status
    echo -e "  ${C_BOLD}Repository${C_RESET}"
    if [[ -d "$REPO_DIR/.git" ]]; then
        local branch commit
        branch=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null)
        commit=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null)
        _step_ok "Cloned at ${C_CYAN}${REPO_DIR}${C_RESET}"
        _step_dim "Branch: ${branch}  Commit: ${commit}"
    else
        _step_warn "Not cloned"
    fi
    echo ""

    # Discovered scripts
    echo -e "  ${C_BOLD}Scripts${C_RESET}"
    if _discover_scripts; then
        for i in "${!_SCRIPT_FILES[@]}"; do
            local basename_sh
            basename_sh=$(basename "${_SCRIPT_FILES[$i]}")
            _step_dim "${basename_sh}: ${_SCRIPT_DESCS[$i]}"
        done
    else
        _step_warn "No scripts found"
    fi
    echo ""

    # Source line
    echo -e "  ${C_BOLD}Shell Integration${C_RESET}"
    local rc_file
    rc_file=$(_detect_rc_file)
    if [[ -f "$rc_file" ]] && grep -qF "$MARKER" "$rc_file"; then
        local sourced_script
        sourced_script=$(grep "$MARKER" "$rc_file" | grep -o 'source "[^"]*"' | sed 's/source "//;s/"$//')
        _step_ok "Source line in $(basename "$rc_file") ${C_DIM}→ $(basename "$sourced_script" 2>/dev/null)${C_RESET}"
    else
        _step_warn "No source line in $(basename "$rc_file")"
    fi

    _hr
}

# ── Uninstall ─────────────────────────────────────────────────────────────────

_do_uninstall() {
    _banner
    echo ""
    echo -e "  ${C_BOLD}${C_RED}Uninstall${C_RESET}"
    echo ""

    # Remove source line
    local rc_file
    rc_file=$(_detect_rc_file)
    if [[ -f "$rc_file" ]] && grep -qF "$MARKER" "$rc_file"; then
        local tmp_file
        tmp_file=$(mktemp)
        grep -v "$MARKER" "$rc_file" > "$tmp_file"
        mv "$tmp_file" "$rc_file"
        _step_ok "Removed source line from $(basename "$rc_file")"
    else
        _step_dim "No source line found in $(basename "$rc_file")"
    fi

    # Prompt to remove repo
    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Remove cloned repo at ${REPO_DIR}? ${C_DIM}[y/N]${C_RESET} "
    read -rsn1 answer
    echo ""
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        rm -rf "$REPO_DIR"
        _step_ok "Removed ${REPO_DIR}"
    else
        _step_dim "Kept ${REPO_DIR}"
    fi

    # Prompt to logout gh
    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Log out of GitHub CLI? ${C_DIM}[y/N]${C_RESET} "
    read -rsn1 answer
    echo ""
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        gh auth logout 2>/dev/null && _step_ok "Logged out of GitHub" || _step_dim "Already logged out"
    else
        _step_dim "Kept GitHub authentication"
    fi

    echo ""
    _step_ok "Uninstall complete"
    _hr
}

# ── Migration from v4 ────────────────────────────────────────────────────────

_migrate_from_v4() {
    local rc_file migrated=0
    rc_file=$(_detect_rc_file)

    # Detect old SSH ONBOARDING marker
    if [[ -f "$rc_file" ]] && grep -qF "$OLD_MARKER" "$rc_file"; then
        _step_info "Migrating from v4${SYM_DOTS}"

        # Replace old source line with new one
        local tmp_file
        tmp_file=$(mktemp)
        grep -v "$OLD_MARKER" "$rc_file" > "$tmp_file"
        echo "$SOURCE_LINE" >> "$tmp_file"
        mv "$tmp_file" "$rc_file"
        _step_ok "Updated source line in $(basename "$rc_file")"
        migrated=1
    fi

    # Clean up old token files
    local old_files=(
        "$HOME/.onboard_github_token"
        "$HOME/.onboard_github_token_type"
        "$HOME/.onboard_last_update"
    )
    for f in "${old_files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            _step_ok "Removed old file: ${C_DIM}$(basename "$f")${C_RESET}"
            migrated=1
        fi
    done

    if [[ "$migrated" -eq 1 ]]; then
        _step_ok "Migration from v4 complete"
        echo ""
    fi
}

# ── Bootstrap Flow ────────────────────────────────────────────────────────────

_bootstrap() {
    _banner
    echo ""

    # Migrate from v4 if needed
    _migrate_from_v4

    # Step 1: Install gh
    _install_gh || return 1
    echo ""

    # Step 2: Install qrencode
    _install_qrencode
    echo ""

    # Step 3: Authenticate
    _authenticate || return 1
    echo ""

    # Step 4: Clone repo
    _clone_repo || return 1
    echo ""

    # Step 5: Install source line
    _install_source_line
    echo ""

    # Step 6: Show script menu
    _show_menu

    echo ""
    _hr
    echo ""
    _step_ok "Bootstrap complete!"
    _step_dim "Open a new shell or run: ${C_CYAN}source $(_detect_rc_file)${C_RESET}"
    echo ""
}

# ── Help ──────────────────────────────────────────────────────────────────────

_show_help() {
    _banner
    echo ""
    echo -e "  ${C_BOLD}Usage:${C_RESET}  bash onboard.sh [option]"
    echo ""
    echo -e "  ${C_BOLD}Options:${C_RESET}"
    echo -e "    ${C_CYAN}(default)${C_RESET}       Run bootstrap flow (install, auth, clone, configure)"
    echo -e "    ${C_CYAN}--menu, -m${C_RESET}      Re-show the script picker menu"
    echo -e "    ${C_CYAN}--update, -u${C_RESET}    Pull latest changes from repo"
    echo -e "    ${C_CYAN}--status, -s${C_RESET}    Show auth, repo, and script status"
    echo -e "    ${C_CYAN}--uninstall${C_RESET}     Remove source line, prompt to clean up"
    echo -e "    ${C_CYAN}--help, -h${C_RESET}      Show this help message"
    echo ""
    _hr
}

# ── CLI Entry Point ──────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --help|-h)
            _show_help
            ;;
        --menu|-m)
            _show_menu
            ;;
        --update|-u)
            _banner
            echo ""
            _do_update
            echo ""
            _hr
            ;;
        --status|-s)
            _show_status
            ;;
        --uninstall)
            _do_uninstall
            ;;
        "")
            _bootstrap
            ;;
        *)
            _step_fail "Unknown option: $1"
            echo ""
            _show_help
            exit 1
            ;;
    esac
}

main "$@"
