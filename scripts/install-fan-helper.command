#!/bin/zsh -f
# Explicit local-build trust: run only after reviewing the app you are installing.
# The app never runs this script itself with administrator privileges.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
[[ $# == 0 || ( $# == 1 && "$1" == --uninstall ) ]] || { print -u2 'Unsupported installer argument'; exit 64; }
if (( EUID != 0 )); then
  print 'MY MACHINE needs administrator permission to install or remove its optional fan helper.'
  exec /usr/bin/sudo /bin/zsh -f "$0" "$@"
fi
readonly SOURCE='/Applications/MY MACHINE.app'
readonly PARENT='/Library/PrivilegedHelperTools'
readonly TARGET="$PARENT/local.mymachine.fancontrol.app"
readonly PLIST='/Library/LaunchDaemons/local.mymachine.fancontrol.plist'
readonly SERVICE='system/local.mymachine.fancontrol'
readonly JOURNAL='/Library/Application Support/local.mymachine.fancontrol/ownership.json'
readonly LOCK="$PARENT/.local.mymachine.fancontrol.install-lock"
MODE=install
[[ $# == 0 ]] || MODE=uninstall
fail() { print -u2 -- "$*"; exit 1; }
# lstat-style tests precede every use of an existing privileged destination.
trusted() {
  [[ -e "$1" && ! -L "$1" ]] || fail "Missing or linked protected path: $1"
  [[ "$(/usr/bin/stat -f %u "$1")" == 0 ]] || fail "Protected path is not owned by root: $1"
  local permissions="$(/usr/bin/stat -f %Lp "$1")"
  (( (8#$permissions & 8#022) == 0 )) || fail "Protected path is writable by others: $1"
}
trusted /Library
for directory in "$PARENT" /Library/LaunchDaemons '/Library/Application Support'; do
  if [[ ! -e "$directory" && ! -L "$directory" ]]; then /bin/mkdir -m 755 "$directory"; fi
  trusted "$directory"
  [[ -d "$directory" ]] || fail "Not a directory: $directory"
done
/bin/mkdir -m 700 "$LOCK" 2>/dev/null || fail "Another fan installer is running (or its lock needs administrator review): $LOCK"
STAGE=''
cleanup() {
  local installer_exit=$?
  # Never discard the only previous installation after a failed/interrupted move.
  if [[ -n "$STAGE" ]]; then
    if (( installer_exit != 0 )) && [[ -e "$STAGE/Previous.app" || -e "$STAGE/previous.plist" ]]; then
      print -u2 "Previous installation retained for administrator recovery: $STAGE"
    else
      /bin/rm -rf -- "$STAGE"
    fi
  fi
  /bin/rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for existing in "$TARGET" "$PLIST"; do
  if [[ -e "$existing" || -L "$existing" ]]; then trusted "$existing"; fi
done
if [[ -e "${JOURNAL:h}" || -L "${JOURNAL:h}" ]]; then trusted "${JOURNAL:h}"; fi
if [[ -e "$JOURNAL" || -L "$JOURNAL" ]]; then trusted "$JOURNAL"; fi
validate_bundle() {
  local bundle="$1"
  [[ -d "$bundle" && ! -L "$bundle" ]] || fail 'Missing application bundle.'
  [[ -z "$(/usr/bin/find "$bundle" -type l -print -quit)" ]] || fail 'Linked files are not accepted in the fan helper bundle.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == local.mymachine.app ]] || fail 'Unexpected app identity.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")" == DailyMac ]] || fail 'Unexpected executable.'
  /usr/bin/codesign --verify --deep --strict "$bundle"
  /usr/bin/codesign -d --verbose=4 "$bundle" 2>&1 | /usr/bin/grep 'flags=.*runtime' >/dev/null || fail 'Hardened runtime is required.'
}
cdhash() { /usr/bin/codesign -d --verbose=4 "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p'; }
digest() { /usr/bin/shasum -a 256 "$1/Contents/MacOS/DailyMac" | /usr/bin/awk '{print $1}'; }
if [[ "$MODE" == install ]]; then
  validate_bundle "$SOURCE"
  ORIGINAL_HASH="$(cdhash "$SOURCE")"
  ORIGINAL_DIGEST="$(digest "$SOURCE")"
  [[ -n "$ORIGINAL_HASH" && -n "$ORIGINAL_DIGEST" ]] || fail 'Cannot identify this local app build.'
  STAGE="$(/usr/bin/mktemp -d "$PARENT/.mymachine-fan.XXXXXXXX")"
  /usr/bin/ditto "$SOURCE" "$STAGE/Helper.app"
  validate_bundle "$STAGE/Helper.app"
  [[ "$(cdhash "$STAGE/Helper.app")" == "$ORIGINAL_HASH" && "$(digest "$STAGE/Helper.app")" == "$ORIGINAL_DIGEST" ]] || fail 'App changed while being copied. Try again.'
  /usr/sbin/chown -R root:wheel "$STAGE/Helper.app"
  /bin/chmod -R go-w "$STAGE/Helper.app"
  validate_bundle "$STAGE/Helper.app"
  /bin/cp "$STAGE/Helper.app/Contents/Resources/local.mymachine.fancontrol.plist" "$STAGE/daemon.plist"
  /bin/chmod 644 "$STAGE/daemon.plist"
  /usr/bin/plutil -lint "$STAGE/daemon.plist"
fi
# Stop the existing helper before recovery. Its signal handler normally restores
# owned fans; the root-only recovery entry covers a crash or pending journal.
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
  /bin/launchctl bootout "$SERVICE" || fail 'Cannot stop the existing fan helper.'
fi
if [[ -d "$TARGET" ]]; then
  validate_bundle "$TARGET"
  [[ -z "$(/usr/bin/find "$TARGET" \( ! -user root -o -perm -022 \) -print -quit)" ]] || fail 'Existing helper contains unprotected files.'
  restored=0
  for attempt in 1 2 3 4 5; do
    if "$TARGET/Contents/MacOS/DailyMac" --fan-helper-restore; then restored=1; break; fi
    /bin/sleep 1
  done
  (( restored == 1 )) || fail 'Automatic restoration is not confirmed. Existing helper and journal retained; do not delete them.'
fi
[[ ! -e "$JOURNAL" && ! -L "$JOURNAL" ]] || fail 'A fan ownership journal remains. Recovery is required before proceeding.'
if [[ "$MODE" == uninstall ]]; then
  [[ ! -e "$PLIST" ]] || /bin/rm -- "$PLIST"
  [[ ! -e "$TARGET" ]] || /bin/rm -rf -- "$TARGET"
  print 'Optional fan helper removed. Any fan control owned by MY MACHINE has been released. Monitoring is unchanged.'
  exit 0
fi
# Preserve the previous root-owned build until the new service starts. Never
# overwrite an existing destination in place or run a user-writable app as root.
[[ ! -e "$TARGET" ]] || /bin/mv "$TARGET" "$STAGE/Previous.app"
[[ ! -e "$PLIST" ]] || /bin/mv "$PLIST" "$STAGE/previous.plist"
/bin/mv "$STAGE/Helper.app" "$TARGET"
/bin/mv "$STAGE/daemon.plist" "$PLIST"
if ! /bin/launchctl bootstrap system "$PLIST"; then
  /bin/rm -rf -- "$TARGET"
  /bin/rm -- "$PLIST"
  [[ ! -e "$STAGE/Previous.app" ]] || /bin/mv "$STAGE/Previous.app" "$TARGET"
  if [[ -e "$STAGE/previous.plist" ]]; then
    /bin/mv "$STAGE/previous.plist" "$PLIST"
    /bin/launchctl bootstrap system "$PLIST" || true
  fi
  fail 'The new helper could not start. The previous installation was restored when available.'
fi
print 'Fan helper installed. Return to MY MACHINE; the controls connect automatically. No manual fan target was applied.'
