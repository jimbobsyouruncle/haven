# Deploy Haven on Jarvis

An eligible protected-main merge triggers [Deploy Control Plane](../.github/workflows/deploy.yml). GitHub validates the exact merge and waits for the pinned sandbox image. It connects over Tailscale using the pinned SSH host key and the restricted `haven-deploy` account. The root systemd service independently checks the active deployment and exact current main, then reconciles the installed checkout and Compose stack. Documentation-only merges skip deployment.

The service holds the deployment locks through installer and health checks. An unsuccessful command fails the unit and the GitHub job. Inspect the failing step on Actions or locally with:

```bash
sudo journalctl -u "haven-deploy@${sha}.service" --no-pager
```

The unit also writes the attempt log at `$HAVEN_LOG_DIR/deploy/$sha.log`. An authorized retry can run against the resulting state. For the same current main commit, rerun **all jobs**. If main has moved, deploy an eligible merge of the fix. Retain the live data in place during diagnosis.

## One-time Jarvis bootstrap

Run from an owner shell on Jarvis after reviewing and merging the replacement PR. Set `sha` to that PR's full **merge commit** from GitHub while it is current main. The driver checks the installed canonical layout, restricted SSH entry point, exact SHA and required PR checks before changing the installed checkout. It uses the same locks and reconciliation as normal deployment. The old journal is inert.

```bash
sudo -i
set -e
sha=REPLACE_WITH_FULL_MERGE_SHA
work="$(mktemp -d /root/haven-deploy.XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
git clone --single-branch --branch main https://github.com/jimbobsyouruncle/haven.git "$work"
test "$(git -C "$work" rev-parse HEAD)" = "$sha"
python3 -IB "$work/scripts/deploy-host.py" --bootstrap "$sha"
exit
```

If bootstrap fails, read its reported step and rerun the same bootstrap after fixing the cause. The next eligible merge uses the unchanged SSH entry point and the replacement systemd unit installed by the bootstrap.

## Storage and recovery

Keep `/opt/haven` for application code and generated configuration. The canonical layout under `/etc/haven` points outside that checkout for persona state, application data, project trees, backups and credentials. Routine reconciliation preserves the existing Compose project, mount paths, and user and group IDs. It never removes persistent volumes or restores a database. A changed service can restart. A failed attempt can leave services partially updated or unavailable.

For disaster recovery:

1. Prepare the host using [bootstrap](../scripts/bootstrap.sh) and obtain a fresh checkout of an approved commit compatible with the snapshot. Use the same persona identities and destination paths from the protected recovery records.
2. Recreate access to the encrypted backup repository independently of the old host or checkout. Rehearse using `backup/restore.sh --test --snapshot SNAPSHOT_ID` from the fresh checkout. For a real restore, follow the [backup runbook](../backup/README.md#restoring) to restore protected configuration and persistent data.
3. Reconcile with `install.sh` against the restored layout and verify with `doctor.sh`, the sandbox firewall check, and the configured HTTPS and authentication routes. Verify the backup timer and a successful snapshot after recovery.

Schema and storage changes can make an older application revision incompatible with live data. Review the migration, confirm a compatible snapshot, and make a deliberate restore decision before replacing live data.

## Declaring an additional persona

Keep one operator-reviewed, credential-free declaration per additional persona.
Use two literal lines in this order:

```dotenv
PERSONA_ID=research
PERSONA_APPS=hermes
```

Run these commands from a trusted checkout as the host administrator. The first
reserves a stable non-root UID/GID and creates private state and project
directories. Repeating it reconciles the same identity and storage. The second
checks the enabled persona's existing identity and storage without writing them.

```bash
sudo ./scripts/provision-persona.sh --declaration < research.env
sudo ./scripts/provision-persona.sh --declaration --check < research.env
```

Set `PERSONA_APPS=` to disable provisioning through the declaration. A disabled
declaration check validates its syntax and reports it disabled. The account,
reserved IDs, and data remain in place for re-enabling. At this stage the
declaration controls provisioning only. Service startup, shutdown, and
deployment reconciliation will consume the declaration in later changes.
Existing Canvas and Hermes use their current setup and deployment paths.
