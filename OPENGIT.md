# How we deployed k3s on opengit infra

## TL;DR

```
export OPENGIT_TOKEN=THIS_IS_KNOWN_BY_BENOIT_MARTIJN_SEBAS
export ANSIBLE_CONFIG=$PWD/ansible.opengit.cfg
ansible-galaxy collection install git+https://github.com/k3s-io/k3s-ansible.git
ansible-playbook k3s.orchestration.site -i inventory
```

## How to use this repo

- copy ansible.cfg.example to ansible.opengit.cfg
  - and modify to use proper username and anything you want customized
- set env var for token
- set env var for ANSIBLE_CONFIG
- get ansible galaxy collections
- run ansible

## updating repo

We can sometimes rebase on upstream main branch, but basically, all we need is this commit
and the latest version of https://github.com/k3s-io/k3s-ansible.
