#!/bin/sh

if [ $# -gt 0 ]; then
    FILE="$1"
    shift
    if [ -f "$FILE" ]; then
        INFO="$(head -n 1 "$FILE")"
    fi
else
    echo "Usage: $0 <filename>"
    exit 1
fi

# Resolve repo root (share/ -> ..)
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CLIENTVERSION_H="$ROOT/src/clientversion.h"

# Read MAJOR.MINOR.REVISION.BUILD from clientversion.h
MAJOR="$(sed -n 's/^#define CLIENT_VERSION_MAJOR[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CLIENTVERSION_H" | head -1)"
MINOR="$(sed -n 's/^#define CLIENT_VERSION_MINOR[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CLIENTVERSION_H" | head -1)"
REVISION="$(sed -n 's/^#define CLIENT_VERSION_REVISION[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CLIENTVERSION_H" | head -1)"
BUILD="$(sed -n 's/^#define CLIENT_VERSION_BUILD[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CLIENTVERSION_H" | head -1)"
BASE_VER="${MAJOR:-1}.${MINOR:-0}.${REVISION:-0}.${BUILD:-0}"

DESC=""
TIME=""
if [ -e "$(which git)" ]; then
    # clean 'dirty' status of touched files that haven't been modified
    git diff >/dev/null 2>/dev/null

    # Prefer git-describe when tags exist (e.g. v0.6.0-66-g59887e8-dirty)
    DESC="$(git describe --dirty 2>/dev/null)"

    # No tags — fall back to vMAJOR.MINOR.REVISION.BUILD-g<shortsha>
    if [ -z "$DESC" ]; then
        SHORT="$(git rev-parse --short=7 HEAD 2>/dev/null)"
        if [ -n "$SHORT" ]; then
            DIRTY=""
            git diff --quiet 2>/dev/null || DIRTY="-dirty"
            DESC="v${BASE_VER}-g${SHORT}${DIRTY}"
        fi
    fi

    TIME="$(git log -n 1 --format="%ci" 2>/dev/null)"
fi

if [ -n "$DESC" ]; then
    NEWINFO="#define BUILD_DESC \"$DESC\""
else
    NEWINFO="// No build information available"
fi

# only update build.h if necessary
if [ "$INFO" != "$NEWINFO" ]; then
    echo "$NEWINFO" >"$FILE"
    echo "#define BUILD_DATE \"$TIME\"" >>"$FILE"
fi
