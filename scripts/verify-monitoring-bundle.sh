#!/bin/zsh -f
set -euo pipefail
[[ $# == 1 && -d "$1/Contents" ]] || exit 64
app="$1"
bin="$app/Contents/MacOS/DailyMac"
[[ -f "$bin" && ! -L "$bin" ]] || exit 1
files=$(/usr/bin/find "$app/Contents" ! -type d -print)
while IFS= read -r path; do
  [[ -f "$path" && ! -L "$path" ]] || exit 1
  case "${path#"$app/Contents/"}" in
    Info.plist|MacOS/DailyMac|Resources/MyMachine.icns|Resources/MyMachineMenuIcon.png|_CodeSignature/CodeResources) ;;
    *) print -u2 -- "Unexpected monitoring bundle payload: $path"; exit 1 ;;
  esac
done <<< "$files"
if LC_ALL=C /usr/bin/grep -aqE -- '--fan-helper|local\.mymachine\.fancontrol|FanControlEngine|FanControlHelper' "$bin"; then
  print -u2 'Monitoring executable includes a removed privileged entry point.'
  exit 1
else
  [[ $? == 1 ]] || exit 1
fi
