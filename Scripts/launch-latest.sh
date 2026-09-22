#!/bin/zsh

set -euo pipefail

readonly app_name="Timepane"
readonly bundle_id="com.wangjiaxun.DynamicCalendar"
readonly script_dir="${0:A:h}"
readonly project_dir="${script_dir:h}"
readonly canonical_app="${project_dir}/build/EventQA/Build/Products/Debug/Timepane.app"
readonly canonical_executable="${canonical_app}/Contents/MacOS/Timepane"
readonly process_pattern='Timepane\.app/Contents/MacOS/Timepane($|[[:space:]])'

print_only=false
if [[ "${1:-}" == "--print-only" ]]; then
  print_only=true
elif [[ $# -gt 0 ]]; then
  print -u2 -- "Usage: ${0:t} [--print-only]"
  exit 64
fi

if [[ ! -x "${canonical_executable}" ]]; then
  print -u2 -- "Canonical build is missing: ${canonical_app}"
  exit 1
fi

info_plist="${canonical_app}/Contents/Info.plist"
actual_bundle_id=$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}" 2>/dev/null || true
)
if [[ "${actual_bundle_id}" != "${bundle_id}" ]]; then
  print -u2 -- "Unexpected bundle identifier: ${actual_bundle_id:-missing}"
  exit 1
fi

print -r -- "Canonical build: ${canonical_app}"
if [[ "${print_only}" == true ]]; then
  exit 0
fi

matching_pids() {
  pgrep -f "${process_pattern}" 2>/dev/null || true
}

stop_existing_instances() {
  local attempts=0
  local -a pids

  pids=("${(@f)$(matching_pids)}")
  if (( ${#pids} == 0 )); then
    return
  fi

  kill -TERM -- "${pids[@]}" 2>/dev/null || true
  while [[ -n "$(matching_pids)" ]]; do
    if (( attempts >= 60 )); then
      pids=("${(@f)$(matching_pids)}")
      (( ${#pids} == 0 )) || kill -KILL -- "${pids[@]}" 2>/dev/null || true
      break
    fi
    sleep 0.05
    attempts=$(( attempts + 1 ))
  done

  if [[ -n "$(matching_pids)" ]]; then
    print -u2 -- "Could not stop every existing Timepane process."
    exit 1
  fi
}

stop_existing_instances
open -n "${canonical_app}"

attempts=0
while true; do
  pids=("${(@f)$(matching_pids)}")
  if (( ${#pids} == 1 )); then
    command_path=$(ps -p "${pids[1]}" -o command= | sed -e 's/^[[:space:]]*//')
    if [[ "${command_path}" == "${canonical_executable}" ]]; then
      print -r -- "Running exactly one instance: PID ${pids[1]}"
      exit 0
    fi
  fi

  if (( attempts >= 100 )); then
    print -u2 -- "Launch verification failed; expected one ${canonical_executable} process."
    exit 1
  fi
  sleep 0.05
  attempts=$(( attempts + 1 ))
done
