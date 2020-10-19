# pdp-docker-authz

This project is based on [opa-docker-authz](https://github.com/open-policy-agent/opa-docker-authz) plugin.

`pdp-docker-authz` is an [authorization plugin](https://docs.docker.com/engine/extend/plugins_authorization/) for the Docker Engine.

The project demonstrates authorization enforcement of Docker API commands by sending the full API requests to a third party component - a Policy Decision Point (PDP) - that is compatible with OPA's API.

Requests sent from Docker engine to the Docker daemon are described [in the Docker docs](https://docs.docker.com/engine/api/latest/).
The requests are evaluated by the PDP which sends a response to the plugin.

The plugin then responds to the Docker daemon, with a response in the following structure:
```
{
   "Allow":              "Determined whether the user is allowed or not",
   "Msg":                "The authorization message",
   "Err":                "The error message if things go wrong"
}
```
Apart from installing and configuring this plugin, you will have to set up the actual server that will evaluate and allow/deny the requests.

## Usage

### Prerequisites

1. a Linux machine running Docker daemon
2. an Open Policy Agent

### Quick Example OPA setup

1. run OPA:
```
docker run -p 9000:9000 openpolicyagent/opa run --server --addr :9000
```
2. create a simple policy that will only allow ```docker run``` using ```hello-world``` image:
```
echo 'package policy.docker.authz
default allow = false

is_docker_run {
        endswith(input.Path, "/containers/create")
}

allow {
        is_docker_run
        input.Body.Image == "hello-world"
}

allow {
        not is_docker_run
}' > example.rego
```
3. configure OPA to use the policy
```
curl -X PUT --data-binary @example.rego http://localhost:9000/v1/policies/example
```
4. preform sanity check
```
>>> curl -X POST -H "Content-Type: application/json" --data '{"input":{"Path":"/some/other"}}' http://localhost:9000/v1/data/policy/docker/authz
{"result":{"allow":true}}
>>> curl -X POST -H "Content-Type: application/json" --data '{"input":{"Path":"/v1.40/containers/create"}}' http://localhost:9000/v1/data/policy/docker/authz
{"result":{"allow":false,"is_docker_run":true}}
>>> curl -X POST -H "Content-Type: application/json" --data '{"input":{"Path":"/v1.40/containers/create", "Body": {"Image": "hello-world"}}}' http://localhost:9000/v1/data/policy/docker/authz
{"result":{"allow":true,"is_docker_run":true}}
>>> curl -X POST -H "Content-Type: application/json" --data '{"input":{"Path":"/v1.40/containers/create", "Body": {"Image": "bye-world"}}}' http://localhost:9000/v1/data/policy/docker/authz
{"result":{"allow":false,"is_docker_run":true}}
```
### Quick Plugin install

```shell script
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/build-security/pdp-docker-authz/master/install.sh)" -s -p "http://localhost:9000/v1/data/policy/docker/authz"
```

### Manual Plugin install
#### 1. Setup configuration, policy decision point address. 

`mkdir -p /etc/docker`

**/etc/docker/pdp_config.json**

```json
{
  "pdp_addr": "http://localhost:9000/v1/data/policy/docker/authz",
  "allow_on_failure": false
}
```
#### 2. Install the pdp-docker-authz plugin.

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

#### 3. Run a simple Docker command to make sure everything is still working.
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

### Limitations & Future Development

1. Currently, the plugin is not supported on Mac.
2. Docker authorization plugin infrastructure also support authorization of the response returned from Docker daemon to the client. Currently, this plugin only authorizes requests from the client to the Docker daemon (and not the responses).
