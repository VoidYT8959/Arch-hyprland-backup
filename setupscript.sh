#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# Caelestia + Hyprland MyBackup Restore Script
# ============================================================
#
# Restores the configuration actually present in this backup.
#
# Features:
#   - Checks that the backup is complete enough to restore
#   - Creates a safety backup BEFORE changing anything
#   - Separates repository packages from AUR packages
#   - Restores Hyprland, Caelestia, Fish, Foot and GTK configs
#   - Restores ~/.local/bin
#   - Restores pacman.conf
#   - Restores executable permissions
#   - Supports --dry-run
#   - Supports --no-packages
#
# IMPORTANT:
# Package versions are NOT frozen by this backup.
# Arch repositories may contain newer versions than the snapshot date.
#
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOME_DIR="$HOME"
CONFIG_DIR="$HOME_DIR/.config"
LOCAL_DIR="$HOME_DIR/.local"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SAFETY_DIR="$HOME_DIR/caelestia-hyprland-pre-restore-$TIMESTAMP"

DRY_RUN=0
NO_PACKAGES=0

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info() {
    printf '\n[+] %s\n' "$*"
}

warn() {
    printf '\n[!] %s\n' "$*" >&2
}

die() {
    printf '\n[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
    ./setupscript.sh

Options:
    --dry-run
        Check the backup and show what would happen.
        Nothing is changed.

    --no-packages
        Restore configuration only.
        Skip package installation.

    -h, --help
        Show this help.
EOF
}

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        --no-packages)
            NO_PACKAGES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $arg"
            ;;
    esac
done

# ------------------------------------------------------------
# Backup validation
# ------------------------------------------------------------

info "Checking backup contents"

required_paths=(
    "Explisit-packages.txt"
    "aur_pkgs.txt"
    "configs/hypr"
    "configs/caelestia"
    "configs/fish"
    "configs/foot"
    "configs/gtk-3.0"
    "configs/gtk-4.0"
    "configs/localbin"
    "pacman-c.txt"
)

for path in "${required_paths[@]}"; do
    if [[ ! -e "$SCRIPT_DIR/$path" ]]; then
        die "Backup is incomplete: missing '$path'"
    fi
done

info "Backup found at:"
printf '    %s\n' "$SCRIPT_DIR"

if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY RUN ENABLED"
    printf 'Nothing will be changed.\n'
fi

# ------------------------------------------------------------
# Command wrapper
# ------------------------------------------------------------

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '  DRY-RUN: '
        printf '%q ' "$@"
        printf '\n'
    else
        "$@"
    fi
}

# ------------------------------------------------------------
# Safety backup
# ------------------------------------------------------------

info "Creating safety backup of current configuration"

if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$SAFETY_DIR"
fi

backup_user_path() {
    local source="$1"
    local relative="$2"
    local destination="$SAFETY_DIR/$relative"

    if [[ -e "$source" || -L "$source" ]]; then

        if [[ "$DRY_RUN" -eq 1 ]]; then
            printf '  DRY-RUN: safety copy %s -> %s\n' \
                "$source" "$destination"
        else
            mkdir -p "$(dirname -- "$destination")"
            cp -a -- "$source" "$destination"
        fi
    fi
}

backup_user_path "$CONFIG_DIR/hypr"       ".config/hypr"
backup_user_path "$CONFIG_DIR/caelestia"  ".config/caelestia"
backup_user_path "$CONFIG_DIR/fish"       ".config/fish"
backup_user_path "$CONFIG_DIR/foot"       ".config/foot"
backup_user_path "$CONFIG_DIR/gtk-3.0"    ".config/gtk-3.0"
backup_user_path "$CONFIG_DIR/gtk-4.0"     ".config/gtk-4.0"
backup_user_path "$LOCAL_DIR/bin"         ".local/bin"

# Quickshell is NOT restored because the actual ZIP does not contain
# ~/.config/Unknown Organization/quickshell.conf.
# We only preserve the current one in the safety backup if it exists.

backup_user_path \
    "$CONFIG_DIR/Unknown Organization/quickshell.conf" \
    ".config/Unknown Organization/quickshell.conf"

# Existing pacman.conf gets backed up separately because it requires sudo.

if [[ -e /etc/pacman.conf ]]; then

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '  DRY-RUN: safety copy /etc/pacman.conf -> %s/pacman.conf\n' \
            "$SAFETY_DIR"
    else
        sudo cp -a -- /etc/pacman.conf "$SAFETY_DIR/pacman.conf"
    fi
fi

# ------------------------------------------------------------
# Restore pacman.conf early
# ------------------------------------------------------------
#
# The saved pacman.conf should be active while package availability
# is checked, so custom repositories from the snapshot are available.
# The original current pacman.conf has already been backed up above.
# ------------------------------------------------------------

info "Restoring saved pacman.conf"

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '  DRY-RUN: /etc/pacman.conf <- %s/pacman-c.txt\n' \
        "$SCRIPT_DIR"
else
    sudo cp -a -- "$SCRIPT_DIR/pacman-c.txt" /etc/pacman.conf
fi

# ------------------------------------------------------------
# Package restoration
# ------------------------------------------------------------

if [[ "$NO_PACKAGES" -eq 1 ]]; then

    info "Skipping package restoration (--no-packages)"

else

    info "Preparing package lists"

    TMP_DIR="$(mktemp -d)"

    cleanup() {
        rm -rf -- "$TMP_DIR"
    }

    trap cleanup EXIT

    # --------------------------------------------------------
    # Important:
    #
    # pacman -Qqe contains explicitly-installed packages,
    # including explicitly-installed AUR packages.
    #
    # pacman -Qqm contains AUR packages.
    #
    # Therefore:
    #
    #     repo packages = explicit packages - AUR packages
    #
    # --------------------------------------------------------

    grep -vE '^[[:space:]]*(#|$)' \
        "$SCRIPT_DIR/Explisit-packages.txt" \
        | sort -u \
        > "$TMP_DIR/explicit-all.txt" || true

    grep -vE '^[[:space:]]*(#|$)' \
        "$SCRIPT_DIR/aur_pkgs.txt" \
        | sort -u \
        > "$TMP_DIR/aur.txt" || true

    comm -23 \
        "$TMP_DIR/explicit-all.txt" \
        "$TMP_DIR/aur.txt" \
        > "$TMP_DIR/repo-explicit.txt"

    # --------------------------------------------------------
    # Repository packages
    # --------------------------------------------------------

    if [[ "$DRY_RUN" -eq 1 ]]; then

        info "Would restore repository packages"
        printf '  Source: %s\n' \
            "$SCRIPT_DIR/Explisit-packages.txt"

    else

        info "Checking available repository packages"

        AVAILABLE_PACKAGES="$(
            pacman -Slq 2>/dev/null | sort -u || true
        )"

        if [[ -z "$AVAILABLE_PACKAGES" ]]; then

            warn "Could not read the enabled repository package database."
            warn "Repository package installation will be skipped."

        else

            printf '%s\n' "$AVAILABLE_PACKAGES" \
                > "$TMP_DIR/available.txt"

            # Packages available from currently enabled repositories.
            comm -12 \
                "$TMP_DIR/repo-explicit.txt" \
                "$TMP_DIR/available.txt" \
                > "$TMP_DIR/repo-install.txt"

            # Packages from the snapshot that are not currently available.
            comm -23 \
                "$TMP_DIR/repo-explicit.txt" \
                "$TMP_DIR/available.txt" \
                > "$TMP_DIR/repo-skipped.txt"

            if [[ -s "$TMP_DIR/repo-install.txt" ]]; then

                info "Installing available repository packages"

                if ! sudo pacman \
                    -S \
                    --needed \
                    --noconfirm \
                    $(cat "$TMP_DIR/repo-install.txt")
                then
                    warn "Some repository packages could not be installed."
                    warn "See the pacman output above."
                fi

            else

                warn "No repository packages were found to install."

            fi

            if [[ -s "$TMP_DIR/repo-skipped.txt" ]]; then

                warn "These snapshot packages are not currently available"
                warn "from the enabled repositories:"

                cat "$TMP_DIR/repo-skipped.txt"

            fi

        fi

        # ----------------------------------------------------
        # AUR packages
        # ----------------------------------------------------

        if [[ -s "$TMP_DIR/aur.txt" ]]; then

            if ! command -v yay >/dev/null 2>&1; then

                warn "yay is not installed."
                warn "AUR packages were NOT restored."

                printf '\nInstall yay and then run:\n'
                printf '    yay -S --needed - < "%s"\n' \
                    "$SCRIPT_DIR/aur_pkgs.txt"

            else

                info "Installing AUR packages"

                if ! yay \
                    -S \
                    --needed \
                    --noconfirm \
                    $(cat "$TMP_DIR/aur.txt")
                then
                    warn "Some AUR packages could not be installed."
                    warn "See the yay output above."
                fi

            fi

        fi

    fi

fi

# ------------------------------------------------------------
# Configuration restoration
# ------------------------------------------------------------

info "Restoring configuration files"

restore_config() {

    local source_relative="$1"
    local destination_relative="$2"

    local source="$SCRIPT_DIR/$source_relative"
    local destination="$CONFIG_DIR/$destination_relative"

    if [[ ! -e "$source" ]]; then
        die "Restore source missing: $source"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then

        printf '  DRY-RUN: replace %s with %s\n' \
            "$destination" \
            "$source"

    else

        mkdir -p "$(dirname -- "$destination")"

        # Remove the current version only AFTER the safety backup exists.
        rm -rf -- "$destination"

        cp -a -- "$source" "$destination"

    fi
}

restore_config "configs/hypr"       "hypr"
restore_config "configs/caelestia"  "caelestia"
restore_config "configs/fish"       "fish"
restore_config "configs/foot"       "foot"
restore_config "configs/gtk-3.0"    "gtk-3.0"
restore_config "configs/gtk-4.0"     "gtk-4.0"

# ------------------------------------------------------------
# ~/.local/bin
# ------------------------------------------------------------

info "Restoring ~/.local/bin"

if [[ "$DRY_RUN" -eq 1 ]]; then

    printf '  DRY-RUN: replace %s/bin with %s/configs/localbin\n' \
        "$LOCAL_DIR" \
        "$SCRIPT_DIR"

else

    mkdir -p "$LOCAL_DIR"

    rm -rf -- "$LOCAL_DIR/bin"

    cp -a \
        -- "$SCRIPT_DIR/configs/localbin" \
        "$LOCAL_DIR/bin"

fi

# ------------------------------------------------------------
# Permissions
# ------------------------------------------------------------

if [[ "$DRY_RUN" -eq 0 ]]; then

    info "Restoring executable permissions"

    if [[ -d "$CONFIG_DIR/hypr/scripts" ]]; then

        find "$CONFIG_DIR/hypr/scripts" \
            -type f \
            -name '*.sh' \
            -exec chmod +x {} +

    fi

    if [[ -d "$LOCAL_DIR/bin" ]]; then

        find "$LOCAL_DIR/bin" \
            -type f \
            -exec chmod +x {} +

    fi

fi

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

if [[ "$DRY_RUN" -eq 1 ]]; then

    info "Dry run complete"

    printf '\nNothing was changed.\n'

else

    info "RESTORE COMPLETE"

    printf '\n'
    printf '============================================================\n'
    printf '  Restore finished.\n'
    printf '============================================================\n'
    printf '\n'

    printf 'Pre-restore safety backup:\n'
    printf '    %s\n' "$SAFETY_DIR"

    printf '\n'

    printf 'The restored configuration came from:\n'
    printf '    %s\n' "$SCRIPT_DIR"

    printf '\n'

    printf 'Next step:\n'
    printf '    Log out of Hyprland and log back in.\n'

    printf '\n'

    printf 'If something is still wrong, DO NOT delete the safety backup.\n'
    printf 'It contains the configuration that existed before restoration.\n'

fi
