// Copyright 2016 The OPA Authors.  All rights reserved.
// Use of this source code is governed by an Apache2
// license that can be found in the LICENSE file.

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	versionpkg "github.com/build-security/pdp-docker-authz/version"
	"github.com/docker/go-plugins-helpers/authorization"
)

// DockerAuthZPlugin implements the authorization.Plugin interface. Every
// request received by the Docker daemon will be forwarded to the AuthZReq
// function. The AuthZReq function returns a response that indicates whether
// the request should be allowed or denied.
type DockerAuthZPlugin struct {
	configFile string
	debug      bool
	instanceID string
}

type PluginConfiguration struct {
	PdpAddr        string `json:"pdp_addr"`
	AllowOnFailure bool   `json:"allow_on_failure"`
}

// AuthZReq is called when the Docker daemon receives an API request. AuthZReq
// returns an authorization.Response that indicates whether the request should
// be allowed or denied.
func (p DockerAuthZPlugin) AuthZReq(r authorization.Request) authorization.Response {
	ctx := context.Background()

	allowed, err := p.evaluate(ctx, r)

	if allowed {
		return authorization.Response{Allow: true}
	} else if err != nil {
		if p.debug {
			log.Printf("Returning PDP decision: %v (error: %v)", true, err)
			return authorization.Response{Allow: true}
		}
		return authorization.Response{Err: err.Error()}
	}

	return authorization.Response{Msg: "request rejected by administrative policy"}
}

// AuthZRes is called before the Docker daemon returns an API response. All responses
// are allowed.
func (p DockerAuthZPlugin) AuthZRes(_ authorization.Request) authorization.Response {
	return authorization.Response{Allow: true}
}

func (p DockerAuthZPlugin) evaluate(_ context.Context, r authorization.Request) (bool, error) {
	bs, err := ioutil.ReadFile(p.configFile)
	if err != nil {
		return false, err
	}

	var cfg PluginConfiguration
	if err = json.Unmarshal(bs, &cfg); err != nil {
		return false, err
	}

	input, err := makeInput(r)
	if err != nil {
		return cfg.AllowOnFailure, err
	}

	body, err := json.Marshal(input)

	allowed, err := func() (bool, error) {
		client := http.Client{
			Timeout: 3 * time.Second,
		}
		resp, err := client.Post(cfg.PdpAddr, "application/json", bytes.NewBuffer(body))

		if err != nil {
			return cfg.AllowOnFailure, err
		}

		defer dclose(resp.Body)
		body, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return cfg.AllowOnFailure, err
		}

		var bodyJSON map[string]interface{}
		if err = json.Unmarshal(body, &bodyJSON); err != nil {
			return cfg.AllowOnFailure, err
		}

		log.Println("Response", bodyJSON)
		var allowed = false

		for i := range bodyJSON {
			nested, ok := bodyJSON[i].(map[string]interface{})

			if !ok {
				continue
			}

			allowed2, ok1 := nested["allow"].(bool)

			if !ok1 {
				continue
			}

			allowed = allowed2
		}

		return allowed, nil
	}()

	decisionId, _ := uuid4()
	configHash := sha256.Sum256(bs)
	labels := map[string]string{
		"app":            "pdp-docker-authz",
		"id":             p.instanceID,
		"plugin_version": versionpkg.Version,
	}
	decisionLog := map[string]interface{}{
		"labels":      labels,
		"decision_id": decisionId,
		"config_hash": hex.EncodeToString(configHash[:]),
		"input":       input,
		"result":      allowed,
		"timestamp":   time.Now().Format(time.RFC3339Nano),
	}

	if err != nil {
		i, _ := json.Marshal(input)
		log.Printf("Returning PDP decision: %v (error: %v; input: %v)", allowed, err, string(i))
	} else {
		log.Printf("Returning PDP decision: %v", allowed)
		dl, _ := json.Marshal(decisionLog)
		log.Println(string(dl))
	}

	return allowed, err
}

func dclose(c io.Closer) {
	if err := c.Close(); err != nil {
		log.Println(err)
	}
}

func makeInput(r authorization.Request) (interface{}, error) {

	var body interface{}

	if r.RequestHeaders["Content-Type"] == "application/json" && len(r.RequestBody) > 0 {
		if err := json.Unmarshal(r.RequestBody, &body); err != nil {
			return nil, err
		}
	}

	u, err := url.Parse(r.RequestURI)
	if err != nil {
		return nil, err
	}

	input := map[string]interface{}{
		"Headers":    r.RequestHeaders,
		"Path":       r.RequestURI,
		"PathPlain":  u.Path,
		"PathArr":    strings.Split(u.Path, "/"),
		"Query":      u.Query(),
		"Method":     r.RequestMethod,
		"Body":       body,
		"User":       r.User,
		"AuthMethod": r.UserAuthNMethod,
	}

	wrapped := map[string]interface{}{
		"input": input,
	}

	return wrapped, nil
}

func uuid4() (string, error) {
	bs := make([]byte, 16)
	n, err := io.ReadFull(rand.Reader, bs)
	if n != len(bs) || err != nil {
		return "", err
	}
	bs[8] = bs[8]&^0xc0 | 0x80
	bs[6] = bs[6]&^0xf0 | 0x40
	return fmt.Sprintf("%x-%x-%x-%x-%x", bs[0:4], bs[4:6], bs[6:8], bs[8:10], bs[10:]), nil
}

func main() {
	pluginName := flag.String("plugin-name", "pdp-docker-authz", "sets the plugin name that will be registered with Docker")
	configFile := flag.String("config-file", "~/.pdp/config.json", "sets the path of the config file to load")
	debug := flag.Bool("debug", false, "sets whether should run in debug mode")
	version := flag.Bool("version", false, "print the version of the plugin")

	flag.Parse()

	if *version {
		fmt.Println("Version:", versionpkg.Version)
		os.Exit(0)
	}

	instanceId, _ := uuid4()
	p := DockerAuthZPlugin{
		configFile: *configFile,
		debug:      *debug,
		instanceID: instanceId,
	}

	h := authorization.NewHandler(p)
	log.Println("Starting server.")
	err := h.ServeUnix(*pluginName, 0)
	log.Fatal(err)
}
