#!/bin/sh
# RosterBot dependency installer
# Supports: apt (Debian/Ubuntu), yum/dnf (RHEL/CentOS/Fedora)
#
# Usage: sudo sh scripts/install-deps.sh

set -e

# ---------------------------------------------------------------------------
# Detect package manager
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
else
    echo "ERROR: No supported package manager found (apt, dnf, yum)." >&2
    echo "       Install the following Perl modules manually via cpan or cpanm:" >&2
    echo "         DBI DBD::SQLite Mojolicious Mail::VRFY TimeDate" >&2
    exit 1
fi

echo "Detected package manager: $PKG_MGR"

# ---------------------------------------------------------------------------
# Check for root
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (or with sudo)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Install packages
# ---------------------------------------------------------------------------
case "$PKG_MGR" in
    apt)
        echo "Updating package lists..."
        apt-get update -qq

        echo "Installing system packages..."
        apt-get install -y \
            perl \
            sqlite3 \
            libdbi-perl \
            libdbd-sqlite3-perl \
            libmojolicious-perl \
            libtimedate-perl

        # Mail::VRFY may not be in apt repos -- try cpanm if not already installed
        if perl -e "use Mail::VRFY; 1" 2>/dev/null; then
            echo "Mail::VRFY already installed, skipping."
        else
            echo ""
            echo "Installing Mail::VRFY from CPAN..."
            cpan -T Mail::VRFY
        fi
        ;;

    dnf|yum)
        echo "Installing system packages..."
        $PKG_MGR install -y \
            perl \
            perl-DBI \
            perl-DBD-SQLite \
            perl-Mojolicious \
            perl-TimeDate \
            sqlite

        # Mail::VRFY may not be in rpm repos -- use cpan if not already installed
        if perl -e "use Mail::VRFY; 1" 2>/dev/null; then
            echo "Mail::VRFY already installed, skipping."
        else
            echo ""
            echo "Installing Mail::VRFY from CPAN..."
            cpan -T Mail::VRFY
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
echo "Verifying installed modules..."
PERL=$(command -v perl)
FAILED=""

for mod in DBI DBD::SQLite Mojo::UserAgent Mojo::IOLoop Mojo::JSON \
           Mail::VRFY Date::Parse; do
    printf "  %-30s" "$mod"
    if "$PERL" -e "use $mod; 1" 2>/dev/null; then
        echo "OK"
    else
        echo "MISSING"
        FAILED="$FAILED $mod"
    fi
done

echo ""
if [ -n "$FAILED" ]; then
    echo "WARNING: Some modules could not be verified:$FAILED"
    echo "         Try installing manually: cpanm$FAILED"
    exit 1
else
    echo "All dependencies installed successfully."
    echo "You can now re-run: ./configure"
fi
