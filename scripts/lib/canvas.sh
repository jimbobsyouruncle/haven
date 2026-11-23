#!/usr/bin/env bash
# Shared by installer preflight and the boot supervisor.
canvas_check_identity() {
  local state="$1" uid="$2" gid="$3"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$(id -u haven-canvas)" == "$uid" && "$(id -g haven-canvas)" == "$gid" ]] || return 1
  [[ "$(getent passwd "$uid" | cut -d: -f1)" == haven-canvas &&
     "$(getent group "$gid" | cut -d: -f1)" == haven-canvas ]] || return 1
  [[ -d "$state" && ! -L "$state" && "$(realpath -e -- "$state")" == "$state" &&
     "$(stat -c '%u:%g:%a' -- "$state")" == "$uid:$gid:700" ]]
}
