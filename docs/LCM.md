# LCM: k3s upgrade runbook (kates1/2/3)

Scope: patch and minor upgrades with the playbooks in this repo, plus the Rook chart bump and the final kernel reboot. The cluster is a three-node HA embedded-etcd k3s cluster with Rook-Ceph. Current k3s: `v1.35.0+k3s1`. Target: `v1.37.2+k3s1`, then the pending kernel reboot. Upgrade one Kubernetes minor per window and pin every version.

## 1. Path

| # | Step | Version | When |
|---|---|---|---|
| 1 | k3s patch | `v1.35.0+k3s1` -> `v1.35.10+k3s1` | first window |
| 2 | Rook chart | `v1.19.0` -> `v1.19.12` -> `v1.20.9` -> `v1.21.1` | after step 1, before step 3 |
| 3 | k3s minor | `v1.35.10+k3s1` -> `v1.36.6+k3s1` | after step 2 |
| 4 | k3s minor | `v1.36.6+k3s1` -> `v1.37.2+k3s1` | after step 3 |
| 5 | kernel reboot | `6.8.0-90`/`6.8.0-111` -> `6.8.0-147` | after step 4 |
| 6 | future minor | `v1.37.2+k3s1` -> next stable | repeat |

Rules:

- One Kubernetes minor per window. Never jump `1.35` -> `1.37`.
- Rook must be at least `v1.20.9` before 1.36. Rook v1.19 supports Kubernetes 1.30-1.35 only.
- Do not combine the Rook bump, a k3s minor, and the reboot in one window.
- Pin `k3s_version` in the inventory. Never use the `stable` channel.
- Every window gets its own etcd snapshots and health gate.
- Versions are as of 2026-11-04. If a newer patch exists, use the latest patch of the same minor.

### Cluster facts

| | kates1 | kates2 | kates3 |
|---|---|---|---|
| IP / ssh port | 95.217.88.156 / 2849 | 95.217.145.242 / 2849 | 95.216.73.32 / 2849 |
| Role | etcd + control-plane, mon, mgr, **RGW**, 2 OSD | etcd + control-plane, mon, 2 OSD | etcd + control-plane, mon, mgr, **2x MDS**, 2 OSD |
| Root disk free | 9.2G (81%) | 9.8G (80%) | 17G (65%) |
| Running kernel | 6.8.0-111 | 6.8.0-90 | 6.8.0-90 |

All three have `6.8.0-147` installed and `/var/run/reboot-required` set. Uptime is 181 days. Both MDS daemons are on kates3 and the only RGW is on kates1, so draining those nodes takes CephFS or S3 down.

## 2. Before every window

### 2.1 Run the repo playbook, not the installed collection

`ansible-galaxy collection list` shows `k3s.orchestration 1.1.1`; that is not this branch. Do not run `k3s.orchestration.upgrade`.

```bash
cd k3s-ansible && git checkout opencommit
source ./ipaddresses.sh
export OPENCOMMIT_TOKEN=...
export ANSIBLE_CONFIG=$PWD/ansible.opencommit.cfg
ansible-galaxy collection install -r collections/requirements.yml
ansible -i inventory server -m ping
ansible-playbook playbooks/upgrade.yml -i inventory --syntax-check
```

You are prompted for the sudo password once per `ansible-playbook` run.

### 2.2 Inventory must contain

```yaml
    k3s_version: v1.35.10+k3s1   # the target for this window
    k3s_server_config_mode: "0600"
    server_config_yaml: |
      flannel-arg:
        - "mtu=1450"
```

The role rewrites `/etc/rancher/k3s/config.yaml` completely. Without `server_config_yaml`, the live `mtu=1450` is lost. Without `0600`, the token is written world-readable.

Expected result: kates1 gets `token`, `tls-san`, `cluster-init`, `flannel-arg`; kates2/3 get `token`, `tls-san`, `server: https://95.217.88.156:6443`, `flannel-arg`.

### 2.3 Token hash

```bash
printf %s "$OPENCOMMIT_TOKEN" | shasum -a 256
ssh -t kates1 'sudo sed -n "s/^K3S_TOKEN=//p" /etc/systemd/system/k3s.service.env | tr -d "\n" | sha256sum'
```

The two hashes must be identical. The real token is in `/etc/systemd/system/k3s.service.env` or `/var/lib/rancher/k3s/server/token` (the part after the last `:`). Do not proceed if they differ.

### 2.4 Baseline gate

On kates1 as `bs`, run `export KUBECONFIG=$HOME/.kube/config`. Plain `kubectl` tries `/etc/rancher/k3s/k3s.yaml` and fails with permission denied.

Baseline before the first window (2026-11-04):

| Check | Expected |
|---|---|
| Nodes | 3x Ready on the current version |
| Non-Running pods | none |
| etcd voters | kates1/2/3 all `True` |
| Rook operator | `docker.io/rook/ceph:v1.19.0` |
| Ceph | `HEALTH_WARN`, 505/505 PGs `active+clean`, 6/6 OSD up/in, mons b,c,d in quorum |
| Known warning | `too many PGs per OSD (252 > max 250)` — pre-existing, leave it alone |
| Must be fixed | `mons b,c are low on available space` |
| MDS | 1 active + 1 hot standby, both on kates3 |
| RGW | 1 daemon, on kates1 |

After the Rook bump, the operator image changes to the chart version you deployed; keep the rest of the baseline.

```bash
kubectl get nodes -o wide
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl get pdb -A
kubectl get nodes -l node-role.kubernetes.io/etcd=true \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="EtcdIsVoter")].status}{"\n"}{end}'
kubectl -n rook-ceph get cephcluster
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

Gate: no warnings other than the known PG warning. No mon low-space, no OSD down, no PG degraded, 3 mons in quorum, 6 OSD up/in. Any new warning means stop.

Fix the mon low-space warning before the window:

```bash
ssh -t kates1 'sudo apt-get clean; sudo journalctl --vacuum-size=500M; du -xh / --max-depth=2 2>/dev/null | sort -rh | head -15'
```

Find the usage before deleting anything. Do not remove the running kernel.

### 2.5 Disk, GitHub and snapshots

```bash
for h in kates1 kates2 kates3; do ssh $h 'df -h /; df -i /'; done
for h in kates1 kates2 kates3; do
  ssh $h 'curl -sIL -m 20 https://github.com/k3s-io/k3s/releases/download/v1.35.10%2Bk3s1/k3s | grep -m1 HTTP'
done
for h in kates1 kates2 kates3; do
  ssh -t $h 'sudo k3s etcd-snapshot save --name pre-v1.35.10 && sudo k3s etcd-snapshot ls | tail -5'
done
```

Substitute the target version in the GitHub URL and snapshot name for later windows. Free space if a node is over about 85%. Snapshots land in `/var/lib/rancher/k3s/server/db/snapshots`; copy one off-node. Etcd snapshots do not contain Ceph data.

### 2.6 What the playbook does

- `playbooks/upgrade.yml` runs servers with `serial: 1`. For each node it stops k3s, rewrites `config.yaml`, runs the install script for the target version, and restarts k3s.
- There is no health gate and no drain. `KillMode=process` keeps containerd shims and pods running while k3s restarts.
- Never run it against all nodes at once. Use `--limit`, one node at a time, and gate by hand (section 4).
- The role will not downgrade. It only acts when the installed version is `<=` `k3s_version`.
- `--check` is not a useful preview; the config write is skipped in check mode.

### 2.7 Announce the window

Users should expect brief API, CephFS and S3 blips, but no data loss.

## 3. Rook chart bump

**When: after `v1.35.10+k3s1`, before `v1.36.6+k3s1`.**

In the infra repo, bump the Rook Helm chart in this order:

| Step | Chart version | Note |
|---|---|---|
| 1 | `v1.19.12` | latest 1.19 patch |
| 2 | `v1.20.9` | minimum for Kubernetes 1.36/1.37 |
| 3 | `v1.21.1` | recommended/latest |

Rook v1.19 supports Kubernetes 1.30-1.35 only. 1.36 and 1.37 need at least `v1.20.9`. Do not start the 1.36 upgrade until the Rook rollout is healthy. Follow the Rook release notes for chart-specific changes. This is separate from `playbooks/upgrade.yml`, which only upgrades k3s.

## 4. Upgrade loop (repeat for every k3s window)

### 4.1 Set the version

Edit `inventory/k3s-ansible.yml` with the target for this window, then check the syntax:

```bash
source ./ipaddresses.sh
export OPENCOMMIT_TOKEN=...
export ANSIBLE_CONFIG=$PWD/ansible.opencommit.cfg
export KUBECONFIG=$HOME/.kube/config
ansible-playbook playbooks/upgrade.yml -i inventory --syntax-check
```

### 4.2 Roll one node at a time

Order: **kates2, kates3, kates1.** kates1 is last because it is the API endpoint the others join through and your kubeconfig points at it.

```bash
# optional insurance; unset at the end
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout

ansible-playbook playbooks/upgrade.yml -i inventory --limit kates2
# gate
ansible-playbook playbooks/upgrade.yml -i inventory --limit kates3
# gate
ansible-playbook playbooks/upgrade.yml -i inventory --limit kates1
# gate
```

### 4.3 Gate after each node

All of this must be green before touching the next node:

```bash
ssh <n> 'k3s --version | head -1; systemctl is-active k3s'
ssh -t <n> 'sudo cat /etc/rancher/k3s/config.yaml | sed -E "s/(token:).*/\1 <redacted>/"; sudo stat -c "%a %n" /etc/rancher/k3s/config.yaml'
ssh <n> 'ip -o link show flannel.1 | grep -o "mtu [0-9]*"'

kubectl get nodes -o wide
kubectl get nodes -l node-role.kubernetes.io/etcd=true \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="EtcdIsVoter")].status}{"\n"}{end}'
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl -n argocd get applications
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

Expected:

- `k3s --version` shows the target version and `systemctl is-active k3s` says `active`.
- `config.yaml` has `flannel-arg` with `mtu=1450`, mode `600`.
- `flannel.1` reports `mtu 1450`.
- The node is `Ready` on the target version; the other two are unchanged.
- All etcd voters are `True`.
- No pods outside `Running`/`Completed`.
- All ArgoCD applications are `Synced`/`Healthy`.
- Ceph shows only the known PG warning; 505 PGs `active+clean`, 3 mons in quorum, 6 OSD up/in.

Wait for PGs to return to `active+clean` before the next node. Budget roughly 15-30 minutes per node for a minor bump, longer for the 1.37 etcd hop.

**Stop and do not proceed** if the node is not `Ready` after about 5 minutes, an etcd member is not a voter, an OSD is down, `config.yaml` is missing `flannel-arg`, an ArgoCD app is `Degraded`, or Ceph shows a new warning. See section 7.

### 4.4 Finish the window

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
kubectl get nodes -o wide
```

Smoke-test RBD, CephFS and S3, then commit the inventory change. Do not commit a token.

## 5. Concrete windows

| Window | From | To | Inventory | Note |
|---|---|---|---|---|
| 1 | `v1.35.0+k3s1` | `v1.35.10+k3s1` | `k3s_version: v1.35.10+k3s1` | patch |
| — | Rook `v1.19.0` | `v1.21.1` (via `v1.19.12`, `v1.20.9`) | infra repo chart | section 3 |
| 2 | `v1.35.10+k3s1` | `v1.36.6+k3s1` | `k3s_version: v1.36.6+k3s1` | containerd 2.3 |
| 3 | `v1.36.6+k3s1` | `v1.37.2+k3s1` | `k3s_version: v1.37.2+k3s1` | etcd `3.6` -> `3.7` |

Window 3 is the etcd `3.6.14` -> `3.7.1` hop. Take fresh snapshots on all three nodes, keep the etcd-voter gate strict, and do not move to the next node while a member is still a learner.

The versions are what the channel returned on 2026-11-04. If a newer patch exists, substitute the latest patch of the same minor; do not substitute a newer minor.

## 6. Final reboot pass

Do this after `v1.37.2+k3s1`. One node at a time:

1. `ceph osd set noout`.
2. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`. Rook PDBs may block this by design. Four app PDBs allow **0** disruptions and will hang the drain: `forgejo/forgejo-db-primary`, `offen/offen-db-primary`, `docs-staging/docs-website-staging-static-site`, `stichting-staging/stichting-website-staging-static-site`. Plan around them; do not use `--disable-eviction`. kates3 holds both MDS, so CephFS goes down while it reboots; kates1 holds the only RGW, so S3 goes down.
3. `ansible-playbook playbooks/reboot.yml -i inventory --limit <node>`.
4. Wait for Ready and the Ceph baseline, then `kubectl uncordon <node>`.
5. Next node. `ceph osd unset noout` at the end.

After the pass:

```bash
for h in kates1 kates2 kates3; do
  ssh $h 'uname -r; test -f /var/run/reboot-required && echo "reboot still required" || echo "reboot clear"'
done
```

All three should report `6.8.0-147-generic` and `reboot clear`. Then clean up on each node:

```bash
# only after confirming uname -r is the new kernel
for h in kates1 kates2 kates3; do
  ssh -t $h 'sudo apt-get autoremove --purge -y && sudo apt-get clean && sudo journalctl --vacuum-size=500M'
done
```

## 7. Rollback / when it goes wrong

- **Node won't start.** Read the logs: `ssh <n> 'journalctl -u k3s -n 100 --no-pager'`. Likely causes are a bad `config.yaml`, a full disk or MTU.
- **Bad config.** Fix `/etc/rancher/k3s/config.yaml` by hand (token, `tls-san`, `server: https://95.217.88.156:6443` on kates2/3, `flannel-arg`), then `sudo systemctl restart k3s`.
- **Need to downgrade.** Same minor only. The role will not do it:
  ```bash
  ssh -t <n> 'sudo INSTALL_K3S_VERSION=<previous> INSTALL_K3S_SKIP_START=true /usr/local/bin/k3s-install.sh && sudo systemctl restart k3s'
  ```
- **etcd lost quorum or is corrupted.** Restore the pre-window snapshot with `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>` on one node, then rejoin the others. This is a last resort. After etcd 3.7, a binary downgrade to 3.6 is not a supported rollback path.
- **Ceph warning.** Stop and keep Ceph untouched. Do not remove OSDs or mons.

## 8. Future minors (1.38+)

Check the next version:

```bash
curl -sS https://update.k3s.io/v1-release/channels \
  | jq -r '.data[] | select(.id=="v1.38") | .latest'
```

Before starting, check the Rook support matrix at https://rook.io/docs/rook/latest-release/Getting-Started/Prerequisites/prerequisites/. If Rook does not list the target minor as supported, bump Rook first, then repeat sections 2 and 4 for k3s and schedule the reboot pass (section 6) when needed. Pin `k3s_version`; do one minor per window.

## 9. Checklist

- [ ] `v1.35.10+k3s1`: pre-flight, token hash, inventory MTU/`0600`, baseline, snapshots, kates2 -> kates3 -> kates1 gates, commit
- [ ] Rook chart `v1.19.12` -> `v1.20.9` -> `v1.21.1`, rollout healthy
- [ ] `v1.36.6+k3s1`: pre-flight, baseline, snapshots, kates2 -> kates3 -> kates1 gates, commit
- [ ] `v1.37.2+k3s1`: pre-flight, fresh snapshots (etcd `3.6` -> `3.7`), kates2 -> kates3 -> kates1 gates, commit
- [ ] `noout` unset, RBD/CephFS/S3 smoke tests passed
- [ ] Reboot pass done; `uname -r` is `6.8.0-147-generic`; `/var/run/reboot-required` is gone
- [ ] Old kernels and disk cleaned up
- [ ] Next minor: Rook support checked first
