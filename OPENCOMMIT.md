# How we deployed k3s on opencommit infra

## TL;DR

```
# Create your own file called ipaddresses.sh (or anything) and put the vars of PROD*_IP for 3 devices in there.
export PROD1_IP="<kates1>"
export PROD2_IP="<kates2>"
export PROD3_IP="<kates3>"

export OPENCOMMIT_TOKEN=THIS_IS_KNOWN_BY_BENOIT_MARTIJN_SEBAS
export ANSIBLE_CONFIG=$PWD/ansible.opencommit.cfg
ansible-galaxy collection install git+https://github.com/k3s-io/k3s-ansible.git
ansible-playbook k3s.orchestration.site -i inventory
```

## How to use this repo

- copy ansible.cfg.example to ansible.opencommit.cfg
  - and modify to use proper username and anything you want customized
- set env vars vor IP's (see above)
- set env var for token
- set env var for ANSIBLE_CONFIG
- get ansible galaxy collections
- run ansible

## updating repo

We can sometimes rebase on upstream main branch, but basically, all we need is this commit
and the latest version of https://github.com/k3s-io/k3s-ansible.

## Yolo Oneliner
### Create ipaddresses.sh with your IPs first, then:
source ipaddresses.sh
export OPENCOMMIT_TOKEN=THIS_IS_KNOWN_BY_BENOIT_MARTIJN_SEBAS
export ANSIBLE_CONFIG=$PWD/ansible.opencommit.cfg
ansible-galaxy collection install git+https://github.com/k3s-io/k3s-ansible.git
ansible-playbook k3s.orchestration.site -i inventory