#!/usr/bin/env bash

# Copyright 2022 Gardar Arnarsson
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.

collection_root=$(pwd | grep -oP ".+\/ansible_collections\/\w+?\/\w+")
targetname=${PWD##*/}
role=$(expr "$targetname" : '\w*-\(\w*\)-\w*')
role_root="$collection_root/roles/$role"
scenario=$(expr "$targetname" : '\w*-\w*-\(\w*\)')
ansible_version="$(ansible --version | head -1 | sed 's/[^0-9\.]*//g')"
ansible_os_family="$(ansible localhost -m setup -a 'gather_subset=!all,!min,os_family filter=ansible_os_family' 2>/dev/null | grep -oP '(?<=ansible_os_family": ")[^"]+')"
declare -A pkgs=(
  ["debian"]="docker.io"
  ["redhat"]="docker"
)

# Install package requirements
if [[ -v "pkgs[${ansible_os_family,,}]" ]]; then
  packages=${pkgs[${ansible_os_family,,}]}
  ansible localhost -m packages -a "name=$packages update_cache=true"
fi

# Install test requirements from role
if [ -f "$role_root/test-requirements.txt"  ]; then
	python -m pip install -r "$role_root/test-requirements.txt"
fi
# Install test requirements from collection
if [ -f "$collection_root/test-requirements.txt"  ]; then
	python -m pip install -r "$collection_root/test-requirements.txt"
fi

# Install ansible version specific requirements
if [ "$(printf '%s\n' "2.12" "$ansible_version" | sort -V | head -n1)" = "2.12" ]; then 
       python -m pip install molecule molecule-plugins[docker]
       ansible-galaxy collection install git+https://github.com/ansible-collections/community.docker.git
       ansible-galaxy collection install -r "$collection_root/requirements.yml"
elif [ "$(printf '%s\n' "2.10" "$ansible_version" | sort -V | head -n1)" = "2.10" ]; then
       python -m pip install molecule molecule-docker
       ansible-galaxy collection install git+https://github.com/ansible-collections/community.docker.git
       ansible-galaxy collection install -r "$collection_root/requirements.yml"
else
       python -m pip install molecule molecule-docker
       req_dir=$(mktemp -d)
       requirements="$(awk '/name:/ {print $3}' < "$collection_root/requirements.yml") https://github.com/ansible-collections/community.docker.git"
       for req in $requirements; do
	       git -C "$req_dir" clone --single-branch --depth 1 "$req"
	       req="${req##*/}"
	       req="${req%.*}"
	       ansible-galaxy collection build "$req_dir/$req" --output-path "$req_dir"
	       ansible-galaxy collection install "$req_dir/${req//./-}"-*.tar.gz
       done
fi

# Define config locations within collection
export MOLECULE_FILE=$collection_root/.config/molecule/config.yml
export YAMLLINT_CONFIG_FILE=$collection_root/.yamllint.yml

# Unset ansible-test variables that break molecule
unset _ANSIBLE_COVERAGE_CONFIG
unset ANSIBLE_PYTHON_INTERPRETER

# Run molecule test
cd "$role_root" || exit
molecule -c "$collection_root/.config/molecule/config.yml" test -s "$scenario"
