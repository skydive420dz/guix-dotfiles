#!/usr/bin/env bash

set -o noclobber -o noglob -o nounset -o pipefail
IFS=$'\n'

FILE_PATH="${1}"
PV_WIDTH="${2}"
PV_HEIGHT="${3}"
IMAGE_CACHE_PATH="${4}"
PV_IMAGE_ENABLED="${5}"

FILE_EXTENSION="${FILE_PATH##*.}"
FILE_EXTENSION_LOWER="$(printf "%s" "${FILE_EXTENSION}" | tr '[:upper:]' '[:lower:]')"

has() {
    command -v "$1" >/dev/null 2>&1
}

mime_type() {
    if has file; then
        file --dereference --brief --mime-type -- "$FILE_PATH"
    else
        printf 'application/octet-stream\n'
    fi
}

preview_text() {
    if has bat; then
        bat --color=always --style=plain --terminal-width "$PV_WIDTH" -- "$FILE_PATH" && exit 5
    fi

    sed -n '1,200p' -- "$FILE_PATH" && exit 5
}

preview_archive() {
    if has atool; then
        atool --list -- "$FILE_PATH" && exit 5
    fi

    case "$FILE_EXTENSION_LOWER" in
        zip)
            unzip -l -- "$FILE_PATH" && exit 5
            ;;
    esac
}

MIME="$(mime_type)"

case "$FILE_EXTENSION_LOWER" in
    json)
        if has jq; then
            jq --color-output . "$FILE_PATH" && exit 5
        fi
        ;;
    odt|ods|odp|sxw)
        if has odt2txt; then
            odt2txt "$FILE_PATH" && exit 5
        fi
        ;;
    bash|c|cc|conf|cpp|css|csv|el|h|hpp|html|ini|js|json|lua|md|nix|org|py|qml|rs|scm|sh|txt|toml|ts|tsx|xml|yaml|yml|zsh)
        preview_text
        ;;
    a|ace|alz|arc|arj|bz|bz2|cab|cpio|gz|jar|lha|lz|lzh|lzma|lzo|rpm|rz|tar|tbz|tbz2|tgz|tlz|txz|xz|zip)
        preview_archive
        ;;
esac

case "$MIME" in
    image/*)
        if [ "$PV_IMAGE_ENABLED" = "True" ]; then
            exit 7
        fi
        if has chafa; then
            chafa --fill=block --symbols=block --size="${PV_WIDTH}x${PV_HEIGHT}" -- "$FILE_PATH" && exit 5
        fi
        ;;
    video/*)
        if [ "$PV_IMAGE_ENABLED" = "True" ] && has ffmpegthumbnailer; then
            ffmpegthumbnailer -i "$FILE_PATH" -o "$IMAGE_CACHE_PATH" -s 0 && exit 6
        fi
        if has mediainfo; then
            mediainfo "$FILE_PATH" && exit 5
        fi
        ;;
    application/pdf)
        if [ "$PV_IMAGE_ENABLED" = "True" ] && has pdftoppm; then
            pdftoppm -f 1 -l 1 -singlefile -jpeg -scale-to-x 1920 -scale-to-y -1 -- "$FILE_PATH" "${IMAGE_CACHE_PATH%.*}" \
                && exit 6
        fi
        if has pdftotext; then
            pdftotext -l 10 -nopgbrk -q -- "$FILE_PATH" - | fmt -w "$PV_WIDTH" && exit 5
        fi
        ;;
    text/*|application/x-shellscript|application/xml|application/json)
        preview_text
        ;;
esac

if has mediainfo; then
    mediainfo "$FILE_PATH" && exit 5
fi

exit 1
