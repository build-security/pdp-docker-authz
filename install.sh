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

JSON_CONFIG=
ACTION="install"
PDP_ADDR=
DEBUG="false"
CONFIG="pdp_config.json"
LOCAL_CONFIG="/etc/docker/$CONFIG"
DOCKERD_CONFIG="/etc/docker/daemon.json"

# TODO: support osx

usage()
{
  echo "usage: install.sh [-d] [-c] [-p] [-u] [-h]"
}

while [ $# -ge 1 ] && [ "$1" != "" ]; do
  case $1 in
    -p | --pdp-addr )       shift
                            PDP_ADDR=$1
                            ;;
    -c | --config )         shift
                            CONFIG=$1
                            ;;
    -u | --uninstall )      ACTION="uninstall"
                            ;;
    -d | --debug )          DEBUG="true"
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
  execute "docker" "plugin" "install" "buildsecurity/pdp-docker-authz:v0.1" "pdp-args=-config-file ${CONFIG} -debug ${DEBUG}"
  docker_plugin_config
  docker_config_restart
}

pdp_config() {
  if [[ ! -f "$LOCAL_CONFIG" ]]; then
    write_file $LOCAL_CONFIG "{}"
  fi

  if [[ ! -z "$PDP_ADDR" ]]; then
    JSON_CONFIG=$(jq ".\"pdp_addr\" = \"$PDP_ADDR\"" $LOCAL_CONFIG)
    write_file $LOCAL_CONFIG "$JSON_CONFIG"
  fi
}

docker_plugin_config() {
  if [[ ! -f "$DOCKERD_CONFIG" ]]; then
    write_file $DOCKERD_CONFIG "{}"
  fi

  JSON_CONFIG=$(jq '."authorization-plugins" += ["buildsecurity/pdp-docker-authz:v0.1"]' $DOCKERD_CONFIG)

  if [ $? -ne 0 ]; then
    abort "jq failure"
  fi

  write_file $DOCKERD_CONFIG "$JSON_CONFIG"
}

docker_plugin_uninstall() {
  docker_plugin_remove_config
  docker_config_restart
  execute "docker" "plugin" "rm" "-f" "buildsecurity/pdp-docker-authz:v0.1"
}

docker_plugin_remove_config() {
  JSON_CONFIG=$(jq 'del(."authorization-plugins"[] | select(. == "buildsecurity/pdp-docker-authz:v0.1"))' $DOCKERD_CONFIG)

  if [ $? -ne 0 ]; then
    abort "jq failure"
  fi

  write_file $DOCKERD_CONFIG "$JSON_CONFIG"
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
  DATA=$2
  # TODO: @Q is supproted from bash 4 - on osx the bash version is too old
  execute_sudo "bash" "-c" "echo ${DATA@Q} | tee $1"
}

# string formatters
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
TTY_UNDERLINE="$(tty_escape "4;39")"
TTY_BLUE="$(tty_mkbold 34)"
TTY_RED="$(tty_mkbold 31)"
TTY_BOLD="$(tty_mkbold 39)"
TTY_RESET="$(tty_escape 0)"

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
  printf "${TTY_BLUE}==>${TTY_BOLD} %s${TTY_RESET}\n" "$(shell_join "$@")"
}

warn() {
  printf "${TTY_RED}Warning${TTY_RESET}: %s\n" "$(chomp "$1")"
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

if [ $ACTION == "install" ]; then
  docker_plugin_install
elif [ $ACTION == "uninstall" ]; then
  docker_plugin_uninstall
fi
