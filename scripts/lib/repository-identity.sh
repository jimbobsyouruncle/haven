#!/usr/bin/env bash
# Source-only repository identity selection. Process environment only: never
# read layout/secret files or infer identity from an untrusted remote.
# The verifier embeds the marked block because install.sh installs it alone.
# scripts/test-repository-identity.sh checks that both copies remain identical.

# BEGIN repository identity selector
hybrid_ai_repository_slug() {
  case "${HYBRID_AI_REPOSITORY_SLUG-jimbobsyouruncle/hybrid-ai}" in
    jimbobsyouruncle/hybrid-ai|jimbobsyouruncle/haven)
      printf '%s' "${HYBRID_AI_REPOSITORY_SLUG-jimbobsyouruncle/hybrid-ai}"
      ;;
    *)
      printf 'repository identity: HYBRID_AI_REPOSITORY_SLUG must select an approved repository\n' >&2
      return 2
      ;;
  esac
}
# END repository identity selector
