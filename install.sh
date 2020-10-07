#!/bin/bash

set -u

# First check if the OS is Linux.
if [[ "$(uname)" = "Linux" ]]; then
  ON_LINUX=1
fi

if [[ -z "${ON_LINUX-}" ]]; then
  STAT="stat -f"
  CHOWN="/usr/sbin/chown"
  CHGRP="/usr/bin/chgrp"
  GROUP="admin"
  TOUCH="/usr/bin/touch"
else
  STAT="stat --printf"
  CHOWN="/bin/chown"
  CHGRP="/bin/chgrp"
  GROUP="$(id -gn)"
  TOUCH="/bin/touch"
fi

json_config=
action="install"
pdp_addr=
debug="false"
config="pdp_config.json"
local_config="/etc/docker/$config"
dockerd_config="/etc/docker/daemon.json"

# TODO: support osx

usage()
{
  echo "usage: install.sh [-d] [-c] [-p] [-u] [-h]"
}

while [ $# -ge 1 ] && [ "$1" != "" ]; do
  case $1 in
    -p | --pdp-addr )       shift
                            pdp_addr=$1
                            ;;
    -c | --config )         shift
                            config=$1
                            ;;
    -u | --uninstall )      action="uninstall"
                            ;;
    -d | --debug )          debug="true"
                            ;;
    -h | --help )           usage
                            exit
                            ;;
    * )                     usage
                            exit 1
  esac
  shift
done

docker_plugin_install() {
  pdp_config
  execute "docker" "plugin" "install" "buildsecurity/pdp-docker-authz:v0.1" "pdp-args=-config-file ${config} -debug ${debug}"
  docker_plugin_config
  docker_config_restart
}

pdp_config() {
  if [[ ! -f "$local_config" ]]; then
    write_file $local_config "{}"
  fi

  if [[ ! -z "$pdp_addr" ]]; then
    json_config=$(jq ".\"pdp_addr\" = \"$pdp_addr\"" $local_config)
    write_file $local_config "$json_config"
  fi
}

docker_plugin_config() {
  if [[ ! -f "$dockerd_config" ]]; then
    write_file $dockerd_config "{}"
  fi

  json_config=$(jq '."authorization-plugins" += ["buildsecurity/pdp-docker-authz:v0.1"]' $dockerd_config)

  if [ $? -ne 0 ]; then
    abort "jq failure"
  fi

  write_file $dockerd_config "$json_config"
}

docker_plugin_uninstall() {
  docker_plugin_remove_config
  docker_config_restart
  execute "docker" "plugin" "rm" "-f" "buildsecurity/pdp-docker-authz:v0.1"
}

docker_plugin_remove_config() {
  json_config=$(jq 'del(."authorization-plugins"[] | select(. == "buildsecurity/pdp-docker-authz:v0.1"))' $dockerd_config)

  if [ $? -ne 0 ]; then
    abort "jq failure"
  fi

  write_file $dockerd_config "$json_config"
}

docker_config_restart() {
  if [[ -z "${ON_LINUX-}" ]]; then
      abort "Please restart your docker daemon"
  else
      execute_sudo "kill" "-HUP" "$(pidof dockerd)"
  fi
}

have_sudo_access() {
  local -a args
  if [[ -n "${SUDO_ASKPASS-}" ]]; then
    args=("-A")
  fi

  if [[ -z "${HAVE_SUDO_ACCESS-}" ]]; then
    if [[ -n "${args[*]-}" ]]; then
      /usr/bin/sudo "${args[@]}" -l mkdir &>/dev/null
    else
      /usr/bin/sudo -l mkdir &>/dev/null
    fi
    HAVE_SUDO_ACCESS="$?"
  fi

  if [[ "$HAVE_SUDO_ACCESS" -ne 0 ]]; then
    abort "Need sudo access (e.g. the user $USER to be an Administrator)!"
  fi

  return "$HAVE_SUDO_ACCESS"
}

write_file() {
  data=$2
  # TODO: @Q is supproted from bash 4 - on osx the bash version is too old
  execute_sudo "bash" "-c" "echo ${data@Q} | tee $1"
}

# string formatters
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_blue="$(tty_mkbold 34)"
tty_red="$(tty_mkbold 31)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " "
    printf "%s" "${arg// /\ }"
  done
}

chomp() {
  printf "%s" "${1/"$'\n'"/}"
}

ohai() {
  printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"
}

warn() {
  printf "${tty_red}Warning${tty_reset}: %s\n" "$(chomp "$1")"
}

abort() {
  printf "%s\n" "$1"
  exit 1
}


execute() {
  if ! "$@"; then
    abort "$(printf "Failed during: %s" "$(shell_join "$@")")"
  fi
}

execute_sudo() {
  local -a args=("$@")
  if [[ -n "${SUDO_ASKPASS-}" ]]; then
    args=("-A" "${args[@]}")
  fi
  if have_sudo_access; then
    ohai "/usr/bin/sudo" "${args[@]}"
    execute "/usr/bin/sudo" "${args[@]}"
  else
    ohai "${args[@]}"
    execute "${args[@]}"
  fi
}

getc() {
  local save_state
  save_state=$(/bin/stty -g)
  /bin/stty raw -echo
  IFS= read -r -n 1 -d '' "$@"
  /bin/stty "$save_state"
}

wait_for_user() {
  local c
  echo
  echo "Press RETURN to continue or any other key to abort"
  getc c
  # we test for \r and \n because some stuff does \r instead
  if ! [[ "$c" == $'\r' || "$c" == $'\n' ]]; then
    exit 1
  fi
}

have_sudo_access

if ! [ -x "$(command -v jq)" ]; then
  abort "Please install jq first"
fi

if [ $action == "install" ]; then
  docker_plugin_install
elif [ $action == "uninstall" ]; then
  docker_plugin_uninstall
fi
