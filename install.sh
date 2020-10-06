#! /bin/bash

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
debug="false"
config="/pdp/pdp_config.json"
dockerd_config="/etc/docker/daemon.json"

usage()
{
    echo "usage: install.sh [[-d] | [-h]]"
}

while [ $# -ge 1 ] && [ "$1" != "" ]; do
    case $1 in
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
    execute "docker" "plugin" "install" "buildsecurity/pdp-docker-authz:v0.1" "pdp-args=\"-config-file ${config} -debug ${debug}\""
    docker_plugin_config
    docker_config_restart
}

docker_plugin_config() {
    if [[ ! -f "$dockerd_config" ]]; then
        cat <<EOF > "$dockerd_config"
{
}
EOF
    fi
    json_config=$(jq '."authorization-plugins" += ["buildsecurity/pdp-docker-authz:v0.1"]' $dockerd_config)

    if [ $? -ne 0 ]; then
        abort "jq failure"
    fi

    cat <<EOF > "$dockerd_config"
$json_config
EOF
}

docker_plugin_uninstall() {
    execute "docker" "plugin" "rm" "-f" "buildsecurity/pdp-docker-authz:v0.1"
    docker_plugin_remove_config
}

docker_plugin_remove_config() {
    json_config=$(jq 'del(."authorization-plugins"[] | select(. == "buildsecurity/pdp-docker-authz:v0.1"))' $dockerd_config)

    if [ $? -ne 0 ]; then
        abort "jq failure"
    fi

    cat <<EOF > "$dockerd_config"
$json_config
EOF
}

docker_config_restart() {
    if [[ -z "${ON_LINUX-}" ]]; then
        abort "Please restart your docker daemon"
    else
        execute "kill" "-HUP" "$(pidof dockerd)"
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

  if [[ -z "${ON_LINUX-}" ]] && [[ "$HAVE_SUDO_ACCESS" -ne 0 ]]; then
    abort "Need sudo access on macOS (e.g. the user $USER to be an Administrator)!"
  fi

  return "$HAVE_SUDO_ACCESS"
}

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

if [ $action == "install" ]; then
    docker_plugin_install
elif [ $action == "uninstall" ]; then
    docker_plugin_uninstall
fi
