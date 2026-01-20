Here's the complete improved version of [`OPENCOMMIT.md`](OPENCOMMIT.md:1) ready to copy-paste:

```markdown
# How we deployed k3s on opencommit infra

## Table of Contents

- [Prerequisites](#prerequisites)
- [TL;DR](#tldr)
- [How to Use This Repo](#how-to-use-this-repo)
- [Environment Variables](#environment-variables)
- [Example ipaddresses.sh](#example-ipaddressessh)

## Prerequisites

- Ansible installed (version 2.10+)
- SSH access to all target machines
- Python 3 installed on target machines
- Sudo privileges on target machines

## TL;DR

```bash
# Create your own file called ipaddresses.sh (or anything) and put the vars of PROD*_IP for 3 devices in there.
export KATES1_IP="<kates1>"
export KATES2_IP="<kates2>"
export KATES3_IP="<kates3>"

export OPENCOMMIT_TOKEN=THIS_IS_KNOWN_BY_BENOIT_MARTIJN_SEBAS
export ANSIBLE_CONFIG=$PWD/ansible.opencommit.cfg
ansible-galaxy collection install git+https://github.com/k3s-io/k3s-ansible.git
ansible-playbook k3s.orchestration.site -i inventory/k3s-ansible.yml
```

## How to Use This Repo

1. Copy ansible.cfg.example to ansible.opencommit.cfg
   - Modify to use proper username and anything you want customized
2. Create `ipaddresses.sh` with your IP addresses (see example below)
3. Set environment variables for IPs (see above)
4. Set environment variable for token
5. Set environment variable for ANSIBLE_CONFIG
6. Install Ansible Galaxy collections
7. Run ansible playbook

## Environment Variables

The following environment variables must be set and correspond to the hosts in `inventory/hosts`:

- `KATES1_IP` → dev1 (ansible_host)
- `KATES2_IP` → dev2 (ansible_host)
- `KATES3_IP` → dev3 (ansible_host)

## Example ipaddresses.sh

Create this file and customize with your actual IPs:

```bash
#!/bin/bash
# ipaddresses.sh - DO NOT COMMIT THIS FILE

export KATES1_IP="192.168.1.10"
export KATES2_IP="192.168.1.11"
export KATES3_IP="192.168.1.12"

# Verify variables are set
echo "IPs configured:"
echo "  KATES1: $KATES1_IP"
echo "  KATES2: $KATES2_IP"
echo "  KATES3: $KATES3_IP"
```

Then add to `.gitignore`:
```
ipaddresses.sh
```