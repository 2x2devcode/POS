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

DESC=""
TIME=""
if [ -e "$(which git)" ]; then
    # clean 'dirty' status of touched files that haven't been modified
    git diff >/dev/null 2>/dev/null

    # Prefer git-describe when tags exist (e.g. v0.6.0-66-g59887e8-dirty)
    DESC="$(git describe --dirty 2>/dev/null)"

    # No tags in this repo — fall back to v1.0.0.1-g<shortsha>
    if [ -z "$DESC" ]; then
        SHORT="$(git rev-parse --short=7 HEAD 2>/dev/null)"
        if [ -n "$SHORT" ]; then
            DIRTY=""
            git diff --quiet 2>/dev/null || DIRTY="-dirty"
            DESC="v1.0.0.1-g${SHORT}${DIRTY}"
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
