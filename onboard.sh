#!/bin/bash

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  SSH Onboarding Script  v3.0                                               ║
# ║  Auto-installs into shell profile, manages screen sessions & Python venv   ║
# ║  Self-updates from private GitHub repo                                     ║
# ╚════════════════════════════════════════════════════════════════════════════╝

ONBOARD_VERSION="3.0.0"

# --- DEFAULT CONFIGURATION ---
BASE_DIR="$HOME/ai"
VENV_DIR="$BASE_DIR/venv"
SCREEN_NAME="ssh"
ATTACH_TIMEOUT=3
REQUIREMENTS_FILE="$BASE_DIR/requirements.txt"
LOCK_DIR="/tmp/onboard-$(id -u)"
LOCK_FILE="$LOCK_DIR/onboard.lock"
SSH_SOCK_STABLE="$HOME/.ssh/ssh_auth_sock"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# --- SELF-UPDATE CONFIGURATION ---
GITHUB_REPO="ryanhebert/personal_scripts"
GITHUB_BRANCH="main"
GITHUB_SCRIPT_PATH="onboard.sh"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/${GITHUB_SCRIPT_PATH}"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/commits?path=${GITHUB_SCRIPT_PATH}&per_page=1&sha=${GITHUB_BRANCH}"
UPDATE_CHECK_INTERVAL=86400  # Check once per day (seconds)
UPDATE_HASH_FILE="$HOME/.onboard_last_update"
GITHUB_TOKEN_FILE="$HOME/.github_token"  # Store PAT here (chmod 600)

# --- USER CONFIG OVERRIDES ---
ONBOARD_RC="$HOME/.onboardrc"
if [[ -f "$ONBOARD_RC" ]]; then
    # shellcheck source=/dev/null
    source "$ONBOARD_RC"
fi

# --- COLORS & SYMBOLS ---
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

SYM_CHECK="✔"
SYM_CROSS="✖"
SYM_ARROW="▶"
SYM_GEAR="⚙"
SYM_SCREEN="◉"
SYM_DOTS="···"
SYM_LINE="─"
SYM_WARN="⚠"
SYM_LOCK="🔒"
SYM_PYTHON="🐍"
SYM_UPDATE="⟳"
SYM_GIT="⎇"

# ─────────────────────────────────────────────────────────────────────────────
# UI HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

_hr() {
    local width=62
    local line=""
    for ((i = 0; i < width; i++)); do line+="$SYM_LINE"; done
    echo -e "${C_GRAY}${line}${C_RESET}"
}

_banner() {
    echo ""
    _hr
    echo -e "${C_BOLD}${C_BLUE}  ${SYM_SCREEN}  SSH Onboarding Environment${C_RESET}  ${C_DIM}v${ONBOARD_VERSION}${C_RESET}"
    echo -e "${C_GRAY}     Screen + Python venv, auto-configured${C_RESET}"
    _hr
}

_step() {
    local symbol="$1" color="$2" message="$3"
    echo -e "  ${color}${symbol}${C_RESET}  ${C_WHITE}${message}${C_RESET}"
}

_step_ok()     { _step "$SYM_CHECK"  "$C_GREEN"   "$1"; }
_step_warn()   { _step "$SYM_WARN"   "$C_YELLOW"  "$1"; }
_step_fail()   { _step "$SYM_CROSS"  "$C_RED"     "$1"; }
_step_info()   { _step "$SYM_GEAR"   "$C_CYAN"    "$1"; }
_step_dim()    { _step "$SYM_DOTS"   "$C_GRAY"    "$1"; }
_step_lock()   { _step "$SYM_LOCK"   "$C_MAGENTA" "$1"; }
_step_update() { _step "$SYM_UPDATE" "$C_BLUE"    "$1"; }
_step_git()    { _step "$SYM_GIT"    "$C_MAGENTA" "$1"; }

_countdown() {
    local seconds="$1"
    for ((i = seconds; i > 0; i--)); do
        printf "\r  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Auto-attaching in ${C_BOLD}${C_YELLOW}%d${C_RESET}${C_WHITE}s ${C_DIM}(press any key to cancel)${C_RESET}  " "$i"
        if read -rsn1 -t 1; then
            printf "\r%-72s\r" " "
            return 0  # Key pressed — cancelled
        fi
    done
    printf "\r%-72s\r" " "
    return 1  # Timeout — no key pressed
}

_sysinfo() {
    local py_ver uptime_str disk_usage load_avg git_ver

    py_ver=$(python3 --version 2>/dev/null | awk '{print $2}' || echo "N/A")
    git_ver=$(git --version 2>/dev/null | awk '{print $3}' || echo "N/A")

    if [[ "$OSTYPE" == "darwin"* ]]; then
        uptime_str=$(uptime | sed 's/.*up/up/' | sed 's/,.*//')
    else
        uptime_str=$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/' | sed 's/,.*//')
    fi

    disk_usage=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s used)", $3, $2, $5}')

    if [[ "$OSTYPE" == "darwin"* ]]; then
        load_avg=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2, $3, $4}')
    else
        load_avg=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)
    fi

    echo ""
    echo -e "  ${C_GRAY}┌─ System ──────────────────────────────────────────────┐${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${SYM_PYTHON} Python:   ${C_CYAN}${py_ver}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ${SYM_GIT}  Git:      ${C_CYAN}${git_ver}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  ⏱  Uptime:   ${C_WHITE}${uptime_str}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  💾 Disk:     ${C_WHITE}${disk_usage}${C_RESET}"
    echo -e "  ${C_GRAY}│${C_RESET}  📊 Load:     ${C_WHITE}${load_avg}${C_RESET}"
    echo -e "  ${C_GRAY}└───────────────────────────────────────────────────────┘${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# GITHUB TOKEN MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

_get_github_token() {
    # Priority: 1) Environment variable  2) Token file  3) git credential helper
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "$GITHUB_TOKEN"
        return 0
    fi

    if [[ -f "$GITHUB_TOKEN_FILE" ]]; then
        local token
        token=$(cat "$GITHUB_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
    fi

    # Try git credential helper as last resort
    local cred_token
    cred_token=$(printf "protocol=https\nhost=github.com\n" | git credential fill 2>/dev/null | grep "password=" | cut -d= -f2)
    if [[ -n "$cred_token" ]]; then
        echo "$cred_token"
        return 0
    fi

    return 1
}

_setup_github_token() {
    _banner
    echo ""
    _step_warn "GitHub token required for private repo access"
    echo ""
    echo -e "  ${C_GRAY}This script auto-updates from:${C_RESET}"
    echo -e "  ${C_CYAN}https://github.com/${GITHUB_REPO}${C_RESET}"
    echo ""
    echo -e "  ${C_GRAY}To generate a Personal Access Token (PAT):${C_RESET}"
    echo -e "  ${C_DIM}  1. Go to ${C_CYAN}https://github.com/settings/tokens${C_RESET}"
    echo -e "  ${C_DIM}  2. Click ${C_WHITE}\"Generate new token (classic)\"${C_RESET}"
    echo -e "  ${C_DIM}  3. Select scope: ${C_WHITE}repo${C_RESET} ${C_DIM}(full control of private repos)${C_RESET}"
    echo -e "  ${C_DIM}  4. Copy the token${C_RESET}"
    echo ""
    echo -e "  ${C_GRAY}You can provide it via:${C_RESET}"
    echo -e "  ${C_DIM}  • File:     ${C_CYAN}echo 'ghp_xxxxx' > ~/.github_token && chmod 600 ~/.github_token${C_RESET}"
    echo -e "  ${C_DIM}  • Env var:  ${C_CYAN}export GITHUB_TOKEN='ghp_xxxxx'${C_RESET}"
    echo -e "  ${C_DIM}  • Prompt:   Enter it now${C_RESET}"
    echo ""

    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Paste token (or press Enter to skip): ${C_RESET}"
    read -rs user_token
    echo ""

    if [[ -n "$user_token" ]]; then
        echo "$user_token" > "$GITHUB_TOKEN_FILE"
        chmod 600 "$GITHUB_TOKEN_FILE"
        _step_ok "Token saved to ${C_CYAN}${GITHUB_TOKEN_FILE}${C_RESET} ${C_DIM}(chmod 600)${C_RESET}"
        return 0
    else
        _step_dim "Skipped — auto-update will be unavailable"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SELF-UPDATE FROM GITHUB
# ─────────────────────────────────────────────────────────────────────────────

_should_check_update() {
    # Returns 0 if we should check, 1 if too soon
    if [[ ! -f "$UPDATE_HASH_FILE" ]]; then
        return 0
    fi

    local last_check
    last_check=$(stat -c %Y "$UPDATE_HASH_FILE" 2>/dev/null || stat -f %m "$UPDATE_HASH_FILE" 2>/dev/null)
    local now
    now=$(date +%s)
    local elapsed=$(( now - last_check ))

    if [[ "$elapsed" -ge "$UPDATE_CHECK_INTERVAL" ]]; then
        return 0
    fi

    return 1
}

_check_for_update() {
    # Skip if inside screen (only check on initial login)
    if [[ -n "$STY" ]]; then return 1; fi

    # Skip if too soon since last check
    if ! _should_check_update; then return 1; fi

    # Need curl or wget
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        return 1
    fi

    # Need a token for private repo
    local token
    token=$(_get_github_token)
    if [[ -z "$token" ]]; then
        return 1
    fi

    _step_update "Checking for updates${C_DIM}${SYM_DOTS}${C_RESET}"

    # Get the latest commit hash for the file
    local remote_hash
    if command -v curl &>/dev/null; then
        remote_hash=$(curl -sf -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    else
        remote_hash=$(wget -qO- --header="Authorization: token ${token}" \
            --header="Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    fi

    if [[ -z "$remote_hash" ]]; then
        _step_dim "Could not reach GitHub ${C_DIM}(skipping update check)${C_RESET}"
        # Touch the file so we don't hammer the API on failure
        touch "$UPDATE_HASH_FILE" 2>/dev/null
        return 1
    fi

    # Compare with stored hash
    local local_hash=""
    if [[ -f "$UPDATE_HASH_FILE" ]]; then
        local_hash=$(cat "$UPDATE_HASH_FILE" 2>/dev/null)
    fi

    if [[ "$remote_hash" == "$local_hash" ]]; then
        _step_ok "Already up to date ${C_DIM}(${remote_hash:0:8})${C_RESET}"
        touch "$UPDATE_HASH_FILE"  # Refresh timestamp
        return 1
    fi

    # New version available
    return 0
}

_perform_update() {
    local token
    token=$(_get_github_token)

    if [[ -z "$token" ]]; then
        _step_fail "No GitHub token available — cannot download update"
        return 1
    fi

    _step_update "Downloading latest version${C_DIM}${SYM_DOTS}${C_RESET}"

    local tmp_file
    tmp_file=$(mktemp /tmp/onboard_update.XXXXXX)

    local http_code
    if command -v curl &>/dev/null; then
        http_code=$(curl -sf -w "%{http_code}" \
            -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/${GITHUB_REPO}/contents/${GITHUB_SCRIPT_PATH}?ref=${GITHUB_BRANCH}" \
            -o "$tmp_file" 2>/dev/null)
    else
        wget -qO "$tmp_file" \
            --header="Authorization: token ${token}" \
            --header="Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/${GITHUB_REPO}/contents/${GITHUB_SCRIPT_PATH}?ref=${GITHUB_BRANCH}" 2>/dev/null
        http_code=$?
        [[ "$http_code" -eq 0 ]] && http_code="200"
    fi

    # Validate download
    if [[ ! -s "$tmp_file" ]]; then
        _step_fail "Download failed — empty file"
        rm -f "$tmp_file"
        return 1
    fi

    # Basic sanity check: must be a bash script
    if ! head -1 "$tmp_file" | grep -q "#!/bin/bash"; then
        _step_fail "Downloaded file doesn't look like a valid script"
        rm -f "$tmp_file"
        return 1
    fi

    # Check for version string in the new file
    local new_version
    new_version=$(grep '^ONBOARD_VERSION=' "$tmp_file" 2>/dev/null | head -1 | cut -d'"' -f2)

    if [[ -z "$new_version" ]]; then
        _step_warn "New file missing version string — proceeding cautiously"
        new_version="unknown"
    fi

    echo ""
    _step_update "Update available: ${C_DIM}v${ONBOARD_VERSION}${C_RESET} → ${C_BOLD}${C_GREEN}v${new_version}${C_RESET}"

    # Show diff summary if diff is available
    if command -v diff &>/dev/null; then
        local changes
        changes=$(diff "$SCRIPT_PATH" "$tmp_file" 2>/dev/null | grep -c "^[<>]")
        _step_dim "${changes} lines changed"
    fi

    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Apply update? ${C_DIM}[Y/n]${C_RESET} "
    read -rsn1 -t 10 answer
    echo ""

    if [[ "$answer" == "n" || "$answer" == "N" ]]; then
        _step_dim "Update skipped"
        # Still record the hash so we don't nag every login
        local remote_hash
        remote_hash=$(curl -sf -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
        echo "$remote_hash" > "$UPDATE_HASH_FILE"
        rm -f "$tmp_file"
        return 1
    fi

    # Backup current script
    local backup_file="${SCRIPT_PATH}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$SCRIPT_PATH" "$backup_file"
    _step_dim "Backup saved: ${C_CYAN}${backup_file}${C_RESET}"

    # Apply update
    mv "$tmp_file" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # Record new hash
    local remote_hash
    if command -v curl &>/dev/null; then
        remote_hash=$(curl -sf -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$GITHUB_API_URL" 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4)
    fi
    echo "$remote_hash" > "$UPDATE_HASH_FILE"

    _step_ok "Updated to ${C_BOLD}v${new_version}${C_RESET}"
    _step_info "Changes take effect on next login or ${C_CYAN}source ${SCRIPT_PATH}${C_RESET}"

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# LOCKING (prevent race conditions)
# ─────────────────────────────────────────────────────────────────────────────

_acquire_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            _step_dim "Another onboard process is running (PID ${lock_pid}), waiting${SYM_DOTS}"
            local wait_count=0
            while [[ -f "$LOCK_FILE" ]] && kill -0 "$lock_pid" 2>/dev/null; do
                sleep 1
                ((wait_count++))
                if [[ "$wait_count" -ge 15 ]]; then
                    _step_warn "Lock timeout — proceeding anyway"
                    break
                fi
            done
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

_release_lock() {
    rm -f "$LOCK_FILE" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH AGENT FORWARDING PRESERVATION
# ─────────────────────────────────────────────────────────────────────────────

_preserve_ssh_agent() {
    if [[ -n "$SSH_AUTH_SOCK" && "$SSH_AUTH_SOCK" != "$SSH_SOCK_STABLE" ]]; then
        mkdir -p "$(dirname "$SSH_SOCK_STABLE")" 2>/dev/null
        ln -sf "$SSH_AUTH_SOCK" "$SSH_SOCK_STABLE" 2>/dev/null
        export SSH_AUTH_SOCK="$SSH_SOCK_STABLE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DEAD SCREEN SESSION CLEANUP
# ─────────────────────────────────────────────────────────────────────────────

_cleanup_dead_screens() {
    local dead_count
    dead_count=$(screen -ls 2>/dev/null | grep -c "Dead")
    if [[ "$dead_count" -gt 0 ]]; then
        _step_warn "Cleaning up ${dead_count} dead screen session(s)${SYM_DOTS}"
        screen -wipe >/dev/null 2>&1
        _step_ok "Dead sessions removed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ROOT CHECK
# ─────────────────────────────────────────────────────────────────────────────

_check_root() {
    if [[ "$EUID" -eq 0 ]]; then
        _step_warn "Running as ${C_RED}root${C_RESET} — this is not recommended"
        _step_dim  "Screen sessions and venvs should be per-user"
        echo ""
        printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Continue as root? ${C_DIM}[y/N]${C_RESET} "
        read -rsn1 -t 5 answer
        echo ""
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            _step_info "Aborted. Login as a regular user instead."
            return 1
        fi
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: CROSS-PLATFORM INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_to_shell_rc() {
    local RC_FILE
    local SHELL_NAME

    if [[ "$OSTYPE" == "darwin"* ]]; then
        RC_FILE="$HOME/.bash_profile"
        SHELL_NAME="macOS Bash"
    else
        RC_FILE="$HOME/.bashrc"
        SHELL_NAME="Linux Bash"
    fi

    if grep -q "# \[SSH ONBOARDING\]" "$RC_FILE" 2>/dev/null; then
        local installed_ver
        installed_ver=$(grep "# onboard-version:" "$RC_FILE" 2>/dev/null | awk '{print $NF}')
        if [[ "$installed_ver" == "$ONBOARD_VERSION" ]]; then
            _step_ok "Already installed ${C_DIM}v${ONBOARD_VERSION}${C_RESET} in ${C_CYAN}${RC_FILE}${C_RESET}"
            return 0
        else
            _step_warn "Upgrading ${C_DIM}v${installed_ver:-unknown}${C_RESET} → ${C_DIM}v${ONBOARD_VERSION}${C_RESET} in ${C_CYAN}${RC_FILE}${C_RESET}"
            sed -i.bak '/# \[SSH ONBOARDING\]/,/^fi$/d' "$RC_FILE"
            rm -f "${RC_FILE}.bak"
        fi
    fi

    _step_info "Installing to ${C_CYAN}${RC_FILE}${C_RESET} ${C_DIM}(${SHELL_NAME})${C_RESET}"

    cat <<EOF >> "$RC_FILE"

# [SSH ONBOARDING] Auto-added by onboard.sh
# onboard-version: $ONBOARD_VERSION
# source-path: $SCRIPT_PATH
if [[ -f "$SCRIPT_PATH" ]]; then
    source "$SCRIPT_PATH"
fi
EOF
    _step_ok "Installation complete — activates on next login"
}

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────

uninstall_from_shell_rc() {
    local RC_FILE

    if [[ "$OSTYPE" == "darwin"* ]]; then
        RC_FILE="$HOME/.bash_profile"
    else
        RC_FILE="$HOME/.bashrc"
    fi

    if ! grep -q "# \[SSH ONBOARDING\]" "$RC_FILE" 2>/dev/null; then
        _step_warn "Not installed in ${C_CYAN}${RC_FILE}${C_RESET} — nothing to remove"
        return 0
    fi

    _step_info "Removing onboard block from ${C_CYAN}${RC_FILE}${C_RESET}"
    sed -i.bak '/# \[SSH ONBOARDING\]/,/^fi$/d' "$RC_FILE"
    sed -i.bak '/^$/N;/^\n$/d' "$RC_FILE"
    rm -f "${RC_FILE}.bak"
    _step_ok "Uninstalled from ${C_CYAN}${RC_FILE}${C_RESET}"

    echo ""
    printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Also remove venv, token, and update data? ${C_DIM}[y/N]${C_RESET} "
    read -rsn1 answer
    echo ""

    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        [[ -d "$VENV_DIR" ]]         && rm -rf "$VENV_DIR"         && _step_ok "Removed ${C_CYAN}${VENV_DIR}${C_RESET}"
        [[ -f "$GITHUB_TOKEN_FILE" ]] && rm -f "$GITHUB_TOKEN_FILE" && _step_ok "Removed ${C_CYAN}${GITHUB_TOKEN_FILE}${C_RESET}"
        [[ -f "$UPDATE_HASH_FILE" ]]  && rm -f "$UPDATE_HASH_FILE"  && _step_ok "Removed ${C_CYAN}${UPDATE_HASH_FILE}${C_RESET}"
        [[ -f "$ONBOARD_RC" ]]        && rm -f "$ONBOARD_RC"        && _step_ok "Removed ${C_CYAN}${ONBOARD_RC}${C_RESET}"
        _step_dim "Kept ${C_CYAN}${BASE_DIR}${C_RESET} (remove manually if desired)"
    else
        _step_dim "Kept all files intact"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS REPORT
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
    _banner
    echo ""

    # Install status
    local RC_FILE
    if [[ "$OSTYPE" == "darwin"* ]]; then RC_FILE="$HOME/.bash_profile"; else RC_FILE="$HOME/.bashrc"; fi

    if grep -q "# \[SSH ONBOARDING\]" "$RC_FILE" 2>/dev/null; then
        local installed_ver
        installed_ver=$(grep "# onboard-version:" "$RC_FILE" 2>/dev/null | awk '{print $NF}')
        _step_ok "Installed in ${C_CYAN}${RC_FILE}${C_RESET} ${C_DIM}(v${installed_ver:-unknown})${C_RESET}"
    else
        _step_fail "Not installed in ${C_CYAN}${RC_FILE}${C_RESET}"
    fi

    # Dependencies
    if command -v screen &>/dev/null; then
        _step_ok "screen: ${C_CYAN}$(screen --version 2>/dev/null | head -1)${C_RESET}"
    else
        _step_fail "screen: ${C_RED}not found${C_RESET}"
    fi

    if command -v python3 &>/dev/null; then
        _step_ok "python3: ${C_CYAN}$(python3 --version 2>/dev/null)${C_RESET}"
    else
        _step_fail "python3: ${C_RED}not found${C_RESET}"
    fi

    if command -v git &>/dev/null; then
        _step_ok "git: ${C_CYAN}$(git --version 2>/dev/null)${C_RESET}"
    else
        _step_fail "git: ${C_RED}not found${C_RESET}"
    fi

    # Venv
    if [[ -d "$VENV_DIR" ]]; then
        _step_ok "Venv: ${C_CYAN}${VENV_DIR}${C_RESET}"
    else
        _step_dim "Venv: ${C_GRAY}not created yet${C_RESET}"
    fi

    # GitHub token
    if _get_github_token &>/dev/null; then
        _step_ok "GitHub token: ${C_GREEN}configured${C_RESET}"
    else
        _step_warn "GitHub token: ${C_YELLOW}not configured${C_RESET} ${C_DIM}(auto-update disabled)${C_RESET}"
    fi

    # Last update check
    if [[ -f "$UPDATE_HASH_FILE" ]]; then
        local last_hash last_time
        last_hash=$(cat "$UPDATE_HASH_FILE" 2>/dev/null)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            last_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$UPDATE_HASH_FILE" 2>/dev/null)
        else
            last_time=$(stat -c "%y" "$UPDATE_HASH_FILE" 2>/dev/null | cut -d. -f1)
        fi
        _step_ok "Last update check: ${C_CYAN}${last_time}${C_RESET} ${C_DIM}(${last_hash:0:8})${C_RESET}"
    else
        _step_dim "Last update check: ${C_GRAY}never${C_RESET}"
    fi

    # Screen sessions
    echo ""
    echo -e "  ${C_GRAY}Active screen sessions:${C_RESET}"
    local sessions
    sessions=$(screen -ls 2>/dev/null | grep -E "\t" || echo "    (none)")
    echo -e "  ${C_DIM}${sessions}${C_RESET}"

    # Config
    echo ""
    echo -e "  ${C_GRAY}Configuration:${C_RESET}"
    echo -e "  ${C_DIM}  BASE_DIR         = ${C_CYAN}${BASE_DIR}${C_RESET}"
    echo -e "  ${C_DIM}  VENV_DIR         = ${C_CYAN}${VENV_DIR}${C_RESET}"
    echo -e "  ${C_DIM}  SCREEN_NAME      = ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    echo -e "  ${C_DIM}  ATTACH_TIMEOUT   = ${C_CYAN}${ATTACH_TIMEOUT}s${C_RESET}"
    echo -e "  ${C_DIM}  GITHUB_REPO      = ${C_CYAN}${GITHUB_REPO}${C_RESET}"
    echo -e "  ${C_DIM}  UPDATE_INTERVAL  = ${C_CYAN}$((UPDATE_CHECK_INTERVAL / 3600))h${C_RESET}"
    if [[ -f "$ONBOARD_RC" ]]; then
        echo -e "  ${C_DIM}  Config file      = ${C_CYAN}${ONBOARD_RC}${C_RESET}"
    else
        echo -e "  ${C_DIM}  Config file      = ${C_GRAY}(not present — using defaults)${C_RESET}"
    fi

    echo ""
    _sysinfo
    echo ""
    _hr
}

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: DEPENDENCY CHECK (Self-Healing)
# ─────────────────────────────────────────────────────────────────────────────

ensure_dependencies() {
    if [[ -n "$STY" ]]; then return; fi

    local NEED_SCREEN=0
    local NEED_PYTHON=0
    local NEED_GIT=0

    command -v screen  &>/dev/null || NEED_SCREEN=1
    command -v python3 &>/dev/null || NEED_PYTHON=1
    command -v git     &>/dev/null || NEED_GIT=1

    if [[ "$NEED_SCREEN" -eq 0 && "$NEED_PYTHON" -eq 0 && "$NEED_GIT" -eq 0 ]]; then
        _step_ok "Dependencies satisfied ${C_DIM}(screen, python3, git)${C_RESET}"
        return 0
    fi

    _step_warn "Installing missing dependencies:"
    [[ "$NEED_SCREEN" -eq 1 ]] && echo -e "     ${C_GRAY}• screen${C_RESET}"
    [[ "$NEED_PYTHON" -eq 1 ]] && echo -e "     ${C_GRAY}• python3${C_RESET}"
    [[ "$NEED_GIT"    -eq 1 ]] && echo -e "     ${C_GRAY}• git${C_RESET}"

    local PACKAGES=()
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        [[ "$NEED_SCREEN" -eq 1 ]] && PACKAGES+=("screen")
        [[ "$NEED_PYTHON" -eq 1 ]] && PACKAGES+=("python3" "python3-venv")
        [[ "$NEED_GIT"    -eq 1 ]] && PACKAGES+=("git")

        _step_lock "Installing: ${C_DIM}${PACKAGES[*]}${C_RESET}"

        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq "${PACKAGES[@]}"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q "${PACKAGES[@]}"
        elif command -v yum &>/dev/null; then
            sudo yum install -y -q "${PACKAGES[@]}"
        else
            _step_fail "Unknown package manager — install manually: ${PACKAGES[*]}"
            return 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        [[ "$NEED_SCREEN" -eq 1 ]] && PACKAGES+=("screen")
        [[ "$NEED_PYTHON" -eq 1 ]] && PACKAGES+=("python3")
        [[ "$NEED_GIT"    -eq 1 ]] && PACKAGES+=("git")

        if command -v brew &>/dev/null; then
            brew install "${PACKAGES[@]}"
        else
            _step_fail "Homebrew not found — install manually: ${PACKAGES[*]}"
            return 1
        fi
    fi

    # Verify
    local all_ok=1
    command -v screen  &>/dev/null || all_ok=0
    command -v python3 &>/dev/null || all_ok=0
    command -v git     &>/dev/null || all_ok=0

    if [[ "$all_ok" -eq 1 ]]; then
        _step_ok "Dependencies installed successfully"
    else
        _step_fail "Some dependencies could not be installed"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PIP REQUIREMENTS AUTO-INSTALL
# ─────────────────────────────────────────────────────────────────────────────

_install_requirements() {
    if [[ ! -f "$REQUIREMENTS_FILE" ]]; then return; fi

    local HASH_FILE="$VENV_DIR/.requirements_hash"
    local CURRENT_HASH
    CURRENT_HASH=$(md5sum "$REQUIREMENTS_FILE" 2>/dev/null || md5 -q "$REQUIREMENTS_FILE" 2>/dev/null)

    if [[ -f "$HASH_FILE" ]] && [[ "$(cat "$HASH_FILE")" == "$CURRENT_HASH" ]]; then
        return
    fi

    _step_info "Installing Python requirements ${C_DIM}(${REQUIREMENTS_FILE})${C_RESET}"

    if pip install -q -r "$REQUIREMENTS_FILE" 2>/dev/null; then
        echo "$CURRENT_HASH" > "$HASH_FILE"
        _step_ok "Requirements installed"
    else
        _step_fail "Failed to install some requirements"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: EXECUTION GUARDS & CLI
# ─────────────────────────────────────────────────────────────────────────────

# Guard: Non-interactive shells — bail silently
[[ $- != *i* ]] && return 2>/dev/null

# Guard: Direct execution — handle CLI flags
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    case "${1:-}" in
        --help|-h)
            _banner
            echo ""
            echo -e "  ${C_BOLD}Usage:${C_RESET}"
            echo -e "    ${C_CYAN}./onboard.sh${C_RESET}                Install into shell profile"
            echo -e "    ${C_CYAN}./onboard.sh --status${C_RESET}       Show current configuration & health"
            echo -e "    ${C_CYAN}./onboard.sh --update${C_RESET}       Force check for updates now"
            echo -e "    ${C_CYAN}./onboard.sh --setup-token${C_RESET}  Configure GitHub token for private repo"
            echo -e "    ${C_CYAN}./onboard.sh --uninstall${C_RESET}    Remove from shell profile"
            echo -e "    ${C_CYAN}./onboard.sh --help${C_RESET}         Show this help"
            echo ""
            echo -e "  ${C_BOLD}Config:${C_RESET}"
            echo -e "    Create ${C_CYAN}~/.onboardrc${C_RESET} to override defaults:"
            echo ""
            echo -e "    ${C_DIM}  BASE_DIR=\"\$HOME/projects\"${C_RESET}"
            echo -e "    ${C_DIM}  SCREEN_NAME=\"dev\"${C_RESET}"
            echo -e "    ${C_DIM}  ATTACH_TIMEOUT=5${C_RESET}"
            echo -e "    ${C_DIM}  UPDATE_CHECK_INTERVAL=3600   # Check hourly${C_RESET}"
            echo ""
            echo -e "  ${C_BOLD}GitHub Token:${C_RESET}"
            echo -e "    Required for auto-update from private repo."
            echo -e "    ${C_DIM}  File:    ${C_CYAN}~/.github_token${C_RESET}  ${C_DIM}(chmod 600)${C_RESET}"
            echo -e "    ${C_DIM}  Env var: ${C_CYAN}GITHUB_TOKEN${C_RESET}"
            echo ""
            _hr
            exit 0
            ;;
        --status|-s)
            show_status
            exit 0
            ;;
        --update|-u)
            _banner
            echo ""
            # Force update check by removing the timestamp constraint
            rm -f "$UPDATE_HASH_FILE"
            if _check_for_update; then
                _perform_update
            fi
            echo ""
            _hr
            exit 0
            ;;
        --setup-token)
            _setup_github_token
            echo ""
            _hr
            exit 0
            ;;
        --uninstall)
            _banner
            echo ""
            uninstall_from_shell_rc
            echo ""
            _hr
            exit 0
            ;;
        --install|"")
            _banner
            echo ""
            _check_root || exit 1
            ensure_dependencies
            install_to_shell_rc
            echo ""

            # Prompt for GitHub token if not configured
            if ! _get_github_token &>/dev/null; then
                echo ""
                _step_warn "GitHub token not configured — auto-updates disabled"
                printf "  ${C_YELLOW}${SYM_ARROW}${C_RESET}  ${C_WHITE}Set up token now? ${C_DIM}[Y/n]${C_RESET} "
                read -rsn1 -t 5 answer
                echo ""
                if [[ "$answer" != "n" && "$answer" != "N" ]]; then
                    _setup_github_token
                fi
            else
                _step_ok "GitHub token: ${C_GREEN}configured${C_RESET}"
            fi

            echo ""
            _hr
            _step_info "Run ${C_CYAN}source ~/.bashrc${C_RESET} or re-login to activate"
            _hr
            echo ""
            exit 0
            ;;
        *)
            _step_fail "Unknown option: ${C_CYAN}$1${C_RESET}"
            echo -e "  ${C_DIM}Run ${C_CYAN}./onboard.sh --help${C_RESET}${C_DIM} for usage${C_RESET}"
            exit 1
            ;;
    esac
fi

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: SCREEN SESSION MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

# Case A: Outside Screen — check for updates, then offer to attach
if [[ -z "$STY" ]]; then
    _check_root || return

    mkdir -p "$BASE_DIR"

    # Preserve SSH agent before screen
    _preserve_ssh_agent

    # Clean up dead sessions
    _cleanup_dead_screens

    # Check for existing sessions
    EXISTING_SESSION=$(screen -ls 2>/dev/null | grep -c "$SCREEN_NAME")

    _banner
    echo ""

    # --- Self-Update Check ---
    if _check_for_update; then
        _perform_update
        echo ""
    fi

    if [[ "$EXISTING_SESSION" -gt 0 ]]; then
        _step_info "Existing session found: ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    else
        _step_info "Creating new session: ${C_CYAN}${SCREEN_NAME}${C_RESET}"
    fi

    echo ""

    # Countdown with opt-out
    if _countdown "$ATTACH_TIMEOUT"; then
        # User cancelled
        echo ""
        _step_warn "Cancelled — normal shell session"
        _step_dim  "To attach manually:  ${C_CYAN}screen -dRR ${SCREEN_NAME}${C_RESET}"
        _step_dim  "Session status:      ${C_CYAN}$(basename "$SCRIPT_PATH") --status${C_RESET}"
        _step_dim  "Force update:        ${C_CYAN}$(basename "$SCRIPT_PATH") --update${C_RESET}"
        _hr
        echo ""
    else
        # Timeout — auto-attach
        _step_ok "Attaching${SYM_DOTS}"
        echo ""
        exec screen -dRR "$SCREEN_NAME"
    fi
fi

# Case B: Inside Screen — set up the environment
if [[ -n "$STY" && "$STY" == *"$SCREEN_NAME"* ]]; then

    _acquire_lock

    mkdir -p "$BASE_DIR"

    # Preserve SSH agent inside screen
    _preserve_ssh_agent

    # Venv creation (one-time)
    if [[ ! -d "$VENV_DIR" ]]; then
        _banner
        echo ""
        _step_info "Building Python venv ${C_DIM}(one-time setup)${C_RESET}"
        if python3 -m venv "$VENV_DIR" 2>/dev/null; then
            _step_ok "Virtual environment created at ${C_CYAN}${VENV_DIR}${C_RESET}"
        else
            _step_fail "Failed to create venv — check python3-venv is installed"
        fi
        echo ""
        _hr
        echo ""
    fi

    # Activate venv
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        source "$VENV_DIR/bin/activate"
    fi

    # Auto-install requirements
    _install_requirements

    _release_lock

    # Move to workspace
    cd "$BASE_DIR" || true

    # Custom prompt
    export PS1="\[${C_RESET}\]\[${C_GREEN}\](venv)\[${C_RESET}\] \[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

    # Welcome message (once per session)
    if [[ -z "$_ONBOARD_WELCOMED" ]]; then
        export _ONBOARD_WELCOMED=1
        echo ""
        _banner
        echo ""
        _step_ok "Screen session:  ${C_CYAN}${SCREEN_NAME}${C_RESET}"
        _step_ok "Python venv:     ${C_CYAN}${VENV_DIR}${C_RESET}"
        _step_ok "Workspace:       ${C_CYAN}${BASE_DIR}${C_RESET}"
        if [[ -n "$SSH_AUTH_SOCK" ]]; then
            _step_ok "SSH Agent:       ${C_CYAN}forwarded${C_RESET}"
        else
            _step_dim "SSH Agent:       ${C_GRAY}not available${C_RESET}"
        fi
        if _get_github_token &>/dev/null; then
            _step_ok "Auto-update:     ${C_CYAN}enabled${C_RESET} ${C_DIM}(${GITHUB_REPO})${C_RESET}"
        else
            _step_warn "Auto-update:     ${C_YELLOW}disabled${C_RESET} ${C_DIM}(no token — run ${C_CYAN}$(basename "$SCRIPT_PATH") --setup-token${C_DIM})${C_RESET}"
        fi

        _sysinfo

        echo ""
        _step_dim "Detach: ${C_WHITE}Ctrl-A D${C_RESET}${C_GRAY}  │  New window: ${C_WHITE}Ctrl-A C${C_RESET}${C_GRAY}  │  List: ${C_WHITE}Ctrl-A \"${C_RESET}"
        _hr
        echo ""
    fi
fi
