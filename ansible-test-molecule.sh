#!/usr/bin/env bash

# Copyright 2022 Gardar Arnarsson
# https://github.com/gardar/ansible-test-molecule
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
#
# Version: 0.1.3

# Set variables
collection_root=$(pwd | grep -oP ".+\/ansible_collections\/\w+?\/\w+")
target=${PWD##*/}
scenario=$(expr "$target" : '\w*-\w*-\(\w*\)')
role=$(expr "$target" : '\w*-\(\w*\)-\w*')
role_root="$collection_root/roles/$role"
ansible_version="$(ansible --version | head -1 | sed 's/[^0-9\.]*//g')"
ansible_os_family="$(ansible localhost -m setup -a 'gather_subset=!all,!min,os_family filter=ansible_os_family' 2>/dev/null | grep -oP '(?<=ansible_os_family": ")[^"]+')"
molecule_file=$collection_root/.config/molecule/config.yml
yamllint_config_file=$collection_root/.yamllint.yml
declare -A pkg=(
	["debian"]="docker.io"
	["redhat"]="docker"
)

check_version() {
	# Parse the current version
	local current_version
	current_version=$(grep -oP '(?<=# Version: )[\d\.]+' "$0")

	local gh_api="https://api.github.com/repos/gardar/ansible-test-molecule/releases/latest"

	# Lookup latest version
	# Use GITHUB_TOKEN if available, to avoid rate limit
	if [[ -v GITHUB_TOKEN ]]
	then
		latest_version=$(curl -s -H "Authorization: token $GITHUB_TOKEN" $gh_api | grep tag_name | cut -d : -f 2 | tr -d '", \n')
	else
		latest_version=$(curl -s $gh_api | grep tag_name | cut -d : -f 2 | tr -d '", \n')
	fi
	
	# Check if a new version exists
	if [[ "$latest_version" != "$current_version" ]]
	then
		echo "A new version of 'ansible-test-molecule' is available: $latest_version" >&2
	fi
}

install_package_requirements() {
	if [[ -v "pkg[${ansible_os_family,,}]" ]]; then
		packages=${pkg[${ansible_os_family,,}]}
		ansible localhost -m package -a "name=$packages update_cache=true"
	fi
}

install_pip_requirements() {
	# Install test requirements from role
	if [ -f "$role_root/test-requirements.txt" ]; then
		python -m pip install -r "$role_root/test-requirements.txt"
	fi
	# Install test requirements from collection
	if [ -f "$collection_root/test-requirements.txt" ]; then
		python -m pip install -r "$collection_root/test-requirements.txt"
	fi
}

install_ansible_requirements() {
	# Install ansible version specific requirements
	if [ "$(printf '%s\n' "2.12" "$ansible_version" | sort -V | head -n1)" = "2.12" ]; then
		python -m pip install molecule molecule-plugins[docker]
		ansible-galaxy collection install git+https://github.com/ansible-collections/community.docker.git
		[ -f "$collection_root/requirements.yml" ] && ansible-galaxy collection install -r "$collection_root/requirements.yml"
	elif [ "$(printf '%s\n' "2.10" "$ansible_version" | sort -V | head -n1)" = "2.10" ]; then
		python -m pip install molecule molecule-docker
		ansible-galaxy collection install git+https://github.com/ansible-collections/community.docker.git
		[ -f "$collection_root/requirements.yml" ] && ansible-galaxy collection install -r "$collection_root/requirements.yml"
	else
		python -m pip install molecule molecule-docker
		if [ -f "$collection_root/requirements.yml" ]; then
			req_dir=$(mktemp -d)
			requirements="$(awk '/name:/ {print $3}' <"$collection_root/requirements.yml") https://github.com/ansible-collections/community.docker.git"
			for req in $requirements; do
				git -C "$req_dir" clone --single-branch --depth 1 "$req"
				req="${req##*/}"
				req="${req%.*}"
				ansible-galaxy collection build "$req_dir/$req" --output-path "$req_dir"
				ansible-galaxy collection install "$req_dir/${req//./-}"-*.tar.gz
			done
		fi
	fi
}

run_molecule() {
	# Define config locations within collection
	export MOLECULE_FILE=$molecule_file
	export YAMLLINT_CONFIG_FILE=$yamllint_config_file

	# Unset ansible-test variables that break molecule
	unset _ANSIBLE_COVERAGE_CONFIG
	unset ANSIBLE_PYTHON_INTERPRETER

	# Run molecule test
	cd "$role_root" || exit
	molecule -c "$molecule_file" test -s "$scenario"
}

main() {
	check_version
	install_package_requirements
	install_pip_requirements
	install_ansible_requirements
	run_molecule
}

main
