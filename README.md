# pdp-docker-authz

This project is based on [opa-docker-authz](https://github.com/open-policy-agent/opa-docker-authz) plugin.

`pdp-docker-authz` is an [authorization plugin](https://docs.docker.com/engine/extend/plugins_authorization/) for the Docker Engine.

## Usage

###1. Setup configuration, policy decision point address. 

`mkdir -p /etc/docker`

**/etc/docker/pdp_config.json**

```json
{
  "pdp_addr": "http://localhost:9000/data/policy/docker.authz",
  "allow_on_failure": false
}
```
###2. Install the pdp-docker-authz plugin.

`docker plugin install buildsecurity/pdp-docker-authz:v0.1 pdp-args="-config-file /pdp/pdp_config.json -debug false"`

You need to configure the Docker daemon to use the plugin for authorization.

```shell script
cat > /etc/docker/daemon.json <<EOF
{
    "authorization-plugins": ["buildsecurity/pdp-docker-authz:v0.1"]
}
EOF
```

Signal the Docker daemon to reload the configuration file.

`kill -HUP $(pidof dockerd)`

### 3. Run a simple Docker command to make sure everything is still working.
`docker ps`

If setup done correctly, the command should exit successfully. You can expect to see log messages from PDP and the plugin.

## Build

A makefile is provided for creating different artifacts, each of which requires Docker:

- `make build` - builds the `pdp-docker-authz` binary
- `make plugin` - builds a managed plugin

**Managed Plugin**

The managed plugin is a special pre-built Docker image, and as such, has no prior knowledge of the user's intended policy. OPA policy defined using the [Rego language](https://www.openpolicyagent.org/docs/language-reference.html), which is handled by another service. The plugin needs to be made aware of the location of the policy decision point, during its installation.

In order to provide PDP address, the plugin configured with a bind mount; `/etc/docker` is mounted at `/pdp` inside the plugin's container, which is its working directory. If you define your policy in a file located at the path `/etc/docker/pdp_config.json`, for example, it will be available to the plugin at `/pdp/pdp_config.json`.

If the plugin installed without a configuration file, all authorization requests sent to the plugin by the Docker daemon, fail open, and are not authorized by the plugin by default.

### Logs

The activity describing the interaction between the Docker daemon and the authorization plugin, and the authorization decisions made by PDP, can be found in the daemon's logs. Their [location](https://docs.docker.com/config/daemon/#read-the-logs) is dependent on the host operating system configuration.

`journalctl -u docker -f`

```
dockerd[908]: map[data.policy.n506c5e8ac58e4ac9bd7145f2184ffffc:map[allow:true] decision_id:20a09f61-de5a-47f9-989d-95db8455b0c7]" plugin=8b1b9db827de8710bd95f79c0052a46e106dd7e058c84e8f31a5f4e7d8d0dd11
dockerd[908]: Returning PDP decision: true" plugin=8b1b9db827de8710bd95f79c0052a46e106dd7e058c84e8f31a5f4e7d8d0dd11
dockerd[908]: {\"config_hash\":\"3baf265ade5e97e09483f1d547ff0cc952cbb4735e1b374dc8e588b547587587\",\"decision_id\":\"a14f6f7b-11a5-462c-9933-16d9d90a80fb\",\"input\":{\"AuthMethod\":\"\",\"Body\":null,\"Headers\":{\"Content-Length\":\"0\",\"Content-Type\":\"text/plain\",\"User-Agent\":\"Docker-Client/19.03.13 (linux)\"},\"Method\":\"POST\",\"Path\":\"/v1.40/containers/7b9fabea0dd7b36a43a5db3073aaf5c340a38fb905e54de4bb072886498c7c5f/start\",\"PathArr\":[\"\",\"v1.40\",\"containers\",\"7b9fabea0dd7b36a43a5db3073aaf5c340a38fb905e54de4bb072886498c7c5f\",\"start\"],\"PathPlain\":\"/v1.40/containers/7b9fabea0dd7b36a43a5db3073aaf5c340a38fb905e54de4bb072886498c7c5f/start\",\"Query\":{},\"User\":\"\"},\"labels\":{\"app\":\"pdp-docker-authz\",\"id\":\"2caae6de-792b-4d9b-8f1f-7ca1edb9430c\",\"plugin_version\":\"v0.1\"},\"result\":true,\"timestamp\":\"2020-09-30T22:07:07.906824127Z\"}" plugin=8b1b9db827de8710bd95f79c0052a46e106dd7e058c84e8f31a5f4e7d8d0dd11
```

### Uninstall

Uninstalling the `pdp-docker-authz` plugin is the reverse of installing. First, remove the configuration applied to the Docker daemon, not forgetting to send a `HUP` signal to the daemon's process.
