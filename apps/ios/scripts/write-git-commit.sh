#!/bin/sh

set -eu

short_commit() {
  candidate="$1"
  case "$candidate" in
    "" | *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#candidate}" -ge 7 ] || return 1
  printf '%.7s' "$candidate" | tr '[:upper:]' '[:lower:]'
}

commit=""
for candidate in "${DASH_GIT_COMMIT:-}" "${CI_COMMIT:-}" "${GITHUB_SHA:-}"; do
  if resolved="$(short_commit "$candidate")"; then
    commit="$resolved"
    break
  fi
done

if [ -z "$commit" ]; then
  repository_commit="$(
    /usr/bin/git -C "${SRCROOT}/../.." rev-parse --verify HEAD 2>/dev/null || true
  )"
  commit="$(short_commit "$repository_commit" || true)"
fi

if [ -z "$commit" ]; then
  if [ "${ACTION:-}" = "install" ] || [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
    printf '%s\n' "error: Dash archive requires a Git commit identity." >&2
    exit 1
  fi
  printf '%s\n' "warning: Dash Git commit identity is unavailable." >&2
fi

output_path="${SCRIPT_OUTPUT_FILE_0:?Missing Git commit output path}"
mkdir -p "${output_path%/*}"
printf '%s' "$commit" > "$output_path"
