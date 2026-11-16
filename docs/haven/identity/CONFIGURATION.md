# Canonical source and configuration handoff

The source/configuration preparation uses `HAVEN_*`, `haven_*` helpers and
`scripts/lib/haven-env.sh`. It does not move host directories, rename accounts,
units, Compose resources or backup archives, or activate automatic deployment.
Those changes require the coordinated transaction and later operational approval
in [ADR-0007](../adr/0007-complete-platform-identity.md).

## Installed configuration compatibility

The canonical helper has an explicit transitional process/key alias list for
installed `HYBRID_AI_*` controls. Canonical and legacy keys with unequal values
in the same process or file refuse before caller activity; an empty value is
also a value for that comparison. Equal aliases are accepted. Duplicate entries
of the same spelling retain the existing last-value semantics. The existing
process-over-layout-over-default precedence and blank/default behavior remain.
Values are literal data, including quotes, dollar signs and backticks. No reader
sources configuration as shell code or logs conflicting values. Vendor variables
and unknown keys are not renamed by prefix matching.

The helper checks the original bootstrap file before following path redirects,
and checks the resolved layout and separate stack file for conflicting known
aliases, even when process overrides exist. Process and file readers share one
explicit alias list. The installer translates only known
keys when it next rewrites an explicitly selected stack file; it retains unowned
settings verbatim, including duplicate-key order, and retains mode 0600.
Known retired settings keep their existing explicit migration rules. Existing
authentication hashes and signing secrets are reused. Layout and secret files
remain separate; preparation does not choose new FHS storage or new identities.

Current shell callers and Compose templates use canonical keys. The old
`hybrid-ai-env.sh` path is a transitional external import adapter, with no separate
resolution/default logic. Standalone installed verification, bootstrap and the
repository selector carry checked identical process-alias blocks. Standalone
maintenance tools import only their own specific legacy process settings.
Historical installation-root journal/control formats remain readable by the
existing protected driver; it accepts either layout spelling and refuses unequal
aliases without changing the journal schema or recovery procedure.

Repository provenance now defaults to `jimbobsyouruncle/haven`. Both selector
variable spellings can select that same identity; neither can actively select
the former slug, another repository or a deceptive URL. A deployment remote
override must also equal the canonical HTTPS clone URL; old redirected or custom
overrides require alignment before any separately authorized deployment. The driver's bounded
historical checkout import remains part of existing migration/recovery support;
its controlled fetch uses the canonical public repository.

The auth service uses canonical credential names and the `haven_auth` cookie.
Existing legacy credential names are accepted as configuration imports, with
unequal aliases failing startup. A valid old `hybrid_ai_auth` cookie is not
accepted: users sign in once after the new auth version is deployed. Signing
secret/hash preservation does not preserve the old cookie name. No OIDC,
permission model or worker interface change is implied.

## Review and recovery

Use the existing environment, auth, rendering, bootstrap, deployment and recovery
suites. `scripts/test-haven-env.sh` adds literal-value, alias-conflict,
precedence and current-source namespace checks with an explicit compatibility
allowlist. Immutable inventories and historical evidence are not absence gates.
Changed Hermes build arguments require the applicable image/non-root CI smoke;
o new worker/GPU observation is required for logger or namespace metadata.

Before any separately approved installation, preserve original protected controls
and the existing transaction/recovery material. A source revert alone cannot
restore a rewritten stack file or an old cookie. Use the existing journaled
recovery procedure and retained matching controls; do not overwrite subsequently
rotated secrets or later application data. The coordinated host handoff must
retire temporary legacy readers only after its installed consumers have moved.
There is no production execution, cleanup or credential rotation in preparation.
