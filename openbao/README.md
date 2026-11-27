# OpenBao

The chart runs a **3-node Raft cluster** that **unseals itself with a static key** and **initialises itself on first start** (self-initialisation, `initialize` block in `templates/configmap-init.yml`), with a daily
**Raft snapshot CronJob**. External Secrets Operator (`eso/`) reads from `http://openbao-active.openbao:8200`.

## How this differs from a manual `bao operator init`

Self-initialization runs the requests in the `initialize "bootstrap"` block once, on the first start with empty storage. OpenBao merges the `initialize` blocks of all config files.

- there is **no `bao operator init`**, and **no recovery keys** are generated;
- the **root token** is not returned to anyone and is revoked once the block has run, so **no root token exists**;
- a failed request aborts the block, and it **never runs again** (running it again means wiping the data volumes). Changing the block later does nothing on a running cluster.

Because there is no root token, the block also creates the temporary `admin` / `admin` account and the `bootstrap-admin` Kubernetes auth role (see step 2) so that someone can log in the first time.

What the initialize block creates:

| What | Details |
|---|---|
| Audit device | `file`, to stdout |
| KV v2 | mounted at `secret/` (`init.kv_path` here must match `kv_path` in `eso/values.yaml`) |
| Policies | `eso-read`, `editor`, `admin`, `snapshot` |
| Auth methods | `userpass` (humans) and `kubernetes` (machines) |
| Temporary user | `userpass` account `admin` / `admin` with the `admin` policy. **Change the password right after the first start** (step 2). |
| Kubernetes roles | `external-secrets` (ESO), `snapshot` (backup CronJob), `bootstrap-admin` (first login) |

`admin` is effectively root-equivalent. It can write any policy and attach it to any user or role (`sys/policies/acl/*`, `auth/userpass/*`, `auth/kubernetes/*`), so it can grant itself anything. It can also enable auth methods and mounts, manage Raft, and save and restore snapshots. Only give it to people who manage the server.

## 0. Before you start

1. The cluster needs **3 nodes**. The chart's default anti-affinity puts one OpenBao pod on each node, so with fewer nodes the extra pods stay `Pending`.
2. Make sure the `openbao` and `external-secrets` namespaces exist (pre-created, or `CreateNamespace=true` on the Applications).
3. Create the unseal key Secret by hand. The pods cannot start without it:

   ```bash
   openssl rand -out unseal.key 32
   wc -c < unseal.key          # must print 32 (raw bytes, no trailing newline)
   kubectl -n openbao create secret generic openbao-unseal-key --from-file=key=unseal.key
   kubectl -n openbao label secret openbao-unseal-key velero.io/exclude-from-backup=true
   ```

   Store `unseal.key` in your password manager, then delete the local file. The OpenBao docs warn that if the seal key is permanently lost, the cluster "cannot be recovered, even from backups".
4. Sync `openbao` first, then `eso` (with `ServerSideApply=true`, the ESO CRDs are large).

## 1. First start

`openbao-0` finds empty storage, initializes itself, unseals with the static key and runs the `initialize` block. The other two pods then join the cluster by themselves (`retry_join`) and unseal with the static key.

```bash
kubectl -n openbao logs openbao-0 | grep -i -E "initializ|error"   # self-init ran, no errors
kubectl -n openbao exec openbao-0 -- bao status                    # Initialized: true, Sealed: false
kubectl -n openbao get pods -w                                     # wait until openbao-0, -1 and -2 are all 1/1 Ready
```

Make sure `openbao-1` and `openbao-2` joined `openbao-0`'s cluster (see `list-peers` in step 2) and did not initialize their own storage.

## 2. First login and human accounts

### Change the temporary `admin` password

The `initialize` block creates a `userpass` account `admin` / `admin` with the `admin` policy. That password is in git and in the `openbao-init` ConfigMap, so **change it as soon as the cluster is up, before anything else**.

```bash
kubectl -n openbao exec -it openbao-0 -- sh
```

In the pod shell (if `bao` cannot find the server, `export BAO_ADDR=http://127.0.0.1:8200`):

```bash
bao login -method=userpass username=admin password=admin
bao write auth/userpass/users/admin/password password='<new strong password>'
bao login -method=userpass username=admin       # log in again with the new password
```

Store the new password in your password manager. If you rebuild the cluster from scratch, the account starts as `admin` / `admin` again until you restore a snapshot or change it again.

### Other accounts, and the `bootstrap-admin` fallback

If the `admin` account is lost, there is no root token. Get a short-lived token for the `openbao-bootstrap` ServiceAccount and exchange it for an `admin` OpenBao token (the `bootstrap-admin` role, 1 hour):

```bash
JWT=$(kubectl -n openbao create token openbao-bootstrap --duration=1h)
kubectl -n openbao exec -it openbao-0 -- sh
```

In the pod shell (if `bao` cannot find the server, `export BAO_ADDR=http://127.0.0.1:8200`):

```bash
export JWT='<paste the token>'
bao write -field=token auth/kubernetes/login role=bootstrap-admin jwt="$JWT" > /tmp/t
export BAO_TOKEN=$(cat /tmp/t); rm /tmp/t

bao operator raft list-peers      # 3 peers and one leader
```

If you need to create a new human account, you can do it through the OpenBao UI, or with the following CLI command:

```bash
bao write auth/userpass/users/<name> password='<temporary>' policies=admin token_ttl=8h token_max_ttl=24h
```

Use `policies=editor` for people who only manage secrets. Have each user change the temporary password at first login.

## 3. Lock down

There is no root token to revoke. Instead, you should **limit who can use `bootstrap-admin`.** Anyone who can run `kubectl -n openbao create token openbao-bootstrap` can get an `admin` token. Anyone who can create a pod in the `openbao` namespace with `serviceAccountName: openbao-bootstrap` gets the same access, and so does anyone with `pods/exec` on a pod that runs as it. Restrict `serviceaccounts/token` create on that ServiceAccount, and pod creation in the `openbao` namespace, with Kubernetes RBAC. Keep the role as the break-glass login: without it, losing all human accounts means rebuilding the cluster.

## Backup and restore

### Backup

The `openbao-backup` CronJob runs daily at 01:00. It logs in to OpenBao with its ServiceAccount (Kubernetes auth role `snapshot`, created by the `initialize` block), runs `bao operator raft snapshot save`, and keeps the snapshots on `openbao-backup-pvc` as `/dumps/<timestamp>.snap` for 30 days.

File-system backup only reads volumes mounted by a running pod. `openbao-backup-pvc` is mounted by the Job only for a few seconds a night, so the always-running `openbao-backup-viewer` pod mounts it so Velero can back it up. The `openbao-backup-viewer` pod is read-only, so it cannot write to the backup volume.

The `openbao-backup-viewer` pod keeps the backup volume mounted read-only, so you can inspect it without a temporary pod.

Snapshots hold all OpenBao data, so treat them as sensitive. Keep the unseal key somewhere other than the backups: you need both to recover.

### Restore

Restoring replaces the whole cluster state with the snapshot. It needs a token that can **update** `sys/storage/raft/snapshot`: the `admin` policy has it, so log in with a human `admin` account or the `bootstrap-admin` role (step 2).

1. Copy the snapshot you want out of the backup volume: `kubectl -n openbao cp openbao-backup-viewer-<pod-suffix>:/dumps/<snapshot>.snap ./<snapshot>.snap`.
2. Find the leader (the pod where `bao status` shows `HA Mode: active`) and copy the snapshot into it. The commands below use `openbao-0`, replace it with the leader's name:

   ```bash
   kubectl -n openbao cp <snapshot>.snap openbao-0:/tmp/restore.snap
   ```
3. Restore (with a token from step 2):

   ```bash
   kubectl -n openbao exec -it openbao-0 -- sh -c 'BAO_ADDR=http://openbao-active:8200 BAO_TOKEN=<admin-token> bao operator raft snapshot restore /tmp/restore.snap'
   ```

   Add `-force` if the snapshot comes from a different cluster, for example when rebuilding from nothing.
4. **After a rebuild from empty volumes (`-force`), restart the pods.** The standbys keep stale state and fail logins until restarted. Delete the pods one at a time, standbys first and the leader (`HA Mode: active`) last, waiting for each to be Ready. A restore on a healthy cluster (no `-force`) does not need this.

## Using a secret from an app

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vmui-auth
  namespace: logging
spec:
  refreshInterval: 1h
  secretStoreRef: { name: openbao, kind: ClusterSecretStore }
  target:
    name: vmui-auth
    template:
      type: kubernetes.io/basic-auth
  data:
    - secretKey: username
      remoteRef: { key: logging/vmui, property: username }
    - secretKey: password
      remoteRef: { key: logging/vmui, property: password }
```

`remoteRef.key` is relative to the KV mount, so it is `logging/vmui`, not `secret/logging/vmui`.

**Scope warning.** The `eso-read` policy lets ESO read every path under `secret/`. The `ClusterSecretStore` in `eso/` only accepts `ExternalSecret`s from the namespaces listed in `openbao.namespaces` in `eso/values.yaml`. **Add a namespace there before it uses the store**; an empty list allows every namespace. Inside an allowed namespace, anyone who can create an `ExternalSecret` can still read any secret in the KV store. For real isolation between teams, use one SecretStore, one Kubernetes auth role and one narrower policy per namespace.

## Rotating the unseal key

Not possible with self-initialization. OpenBao can only re-encrypt its stored keys under a new seal key when a recovery key exists, and self-init creates none . Adding a new `current_key` and keeping the old one as `previous_key` works, but the old key stays required forever, so it protects nothing new. Treat the unseal key as permanent.

## Operations

- **Changes to the `initialize` block do not apply to a running cluster.** It only runs on first start. To change a policy or role on a live cluster, do it with `bao` (logged in as `admin`) and update the ConfigMap template, `files/policies/` or the `init:` values so a rebuilt cluster matches.
- **Never start the pods in parallel on empty storage.** With self-initialization, pods that start together each initialise their own cluster. Keep `podManagementPolicy: OrderedReady` (set in `values.yaml`) so `openbao-0` initialises first and the others join it. After any rebuild, check that `bao operator raft list-peers` shows 3 peers.
- **Quorum**: with 3 nodes the cluster survives the loss of one. If two pods are down, OpenBao stops serving writes until one returns.
- **The static key is the root of trust.** Anyone who can read the `openbao-unseal-key` Secret and a data volume can decrypt the data. Limit who can read that Secret. The Secret is mounted into the OpenBao pods, so `pods/exec` on those pods (or pod creation in the `openbao` namespace) is as good as reading it: limit those RBAC permissions too.
