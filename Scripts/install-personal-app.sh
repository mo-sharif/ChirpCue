#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app="$project_root/dist/ChirpCue.app"
destination_app="/Applications/ChirpCue.app"
staging_root=""
staging_app=""

case "$destination_app" in
    /Applications/ChirpCue.app) ;;
    *) printf '%s\n' "Refusing unsafe application destination" >&2; exit 1 ;;
esac
if test -e "$destination_app" || test -L "$destination_app"; then
    printf '%s\n' "ChirpCue is already installed. Remove the existing app deliberately before replacing it." >&2
    exit 1
fi

cleanup_failed_install() {
    case "$staging_root" in
        /Applications/.ChirpCue.install.??????)
            if test -d "$staging_root" && ! test -L "$staging_root"; then
                /bin/rm -rf -- "$staging_root"
            fi
            ;;
    esac
}
trap cleanup_failed_install EXIT
trap 'exit 1' HUP INT TERM

staging_root=$(/usr/bin/mktemp -d "/Applications/.ChirpCue.install.XXXXXX")
case "$staging_root" in
    /Applications/.ChirpCue.install.??????) ;;
    *) printf '%s\n' "Refusing unsafe staging directory" >&2; exit 1 ;;
esac
staging_app="$staging_root/ChirpCue.app"

"$project_root/Scripts/verify-app.sh" "$source_app"
/usr/bin/ditto "$source_app" "$staging_app"
"$project_root/Scripts/verify-app.sh" "$staging_app"
/bin/mv -n "$staging_app" /Applications/
if test -e "$staging_app" || test -L "$staging_app"; then
    printf '%s\n' "ChirpCue appeared at the install destination during installation; nothing was replaced." >&2
    exit 1
fi
/bin/rmdir "$staging_root"
staging_root=""
"$project_root/Scripts/verify-app.sh" "$destination_app"

trap - EXIT HUP INT TERM
printf '%s\n' "Installed $destination_app"
