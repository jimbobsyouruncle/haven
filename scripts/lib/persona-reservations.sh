#!/usr/bin/env bash
# Shared snapshot and provisioner validation. Records are name:uid:gid.
persona_valid_name() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,25}$ ]] || return 1
  case "$1" in
    backup|deploy|hermes|ollama|webui) return 1 ;;
  esac
  return 0
}

persona_validate_reservations() {
  [[ -s "$1" ]] || return 1
  LC_ALL=C awk -F: '
    NF != 3 || $1 !~ /^[a-z][a-z0-9-]*$/ || length($1) > 26 ||
    $1 ~ /^(backup|deploy|hermes|ollama|webui)$/ ||
    $2 !~ /^[1-9][0-9][0-9]$/ || $3 !~ /^[1-9][0-9][0-9]$/ ||
    names[$1]++ || uids[$2]++ || gids[$3]++ {exit 1}
  ' "$1" && [[ "$(tail -c 1 -- "$1" | wc -l)" -eq 1 ]]
}
