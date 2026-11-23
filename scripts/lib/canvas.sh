#!/usr/bin/env bash
# Shared by installer preflight and the boot supervisor.
canvas_check_identity() {
  local state="$1" uid="$2" gid="$3"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$(id -u haven-canvas)" == "$uid" && "$(id -g haven-canvas)" == "$gid" ]] || return 1
  [[ "$(getent passwd "$uid" | cut -d: -f1)" == haven-canvas &&
     "$(getent group "$gid" | cut -d: -f1)" == haven-canvas ]] || return 1
  # The agent owns the mounted child, so keep a root-only, unmounted parent
  # to preserve host-side privacy even if the agent changes child modes.
  [[ -d "$state/persona" && "$(realpath -e -- "$state/persona")" == "$state/persona" &&
     -d "$state/projects" && "$(realpath -e -- "$state/projects")" == "$state/projects" &&
     "$(stat -c '%u:%g:%a' -- "$state")" == 0:0:700 &&
     "$(stat -c '%u:%g:%a' -- "$state/projects")" == "$uid:$gid:700" &&
     "$(stat -c '%u:%g:%a' -- "$state/persona")" == "$uid:$gid:700" ]]
}
