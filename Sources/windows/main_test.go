package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestPromptConnection(t *testing.T) {
	reader := bufio.NewReader(strings.NewReader("invalid host\r\nDev@[2001:DB8::1]:2222\r\n\r\n\r\n~/Project files/a'b\r\n"))
	var output strings.Builder
	config, err := promptConnection(reader, &output, "LocalUser")
	if err != nil {
		t.Fatal(err)
	}
	expected := connection{host: "2001:db8::1", username: "Dev", port: 2222, directory: "~/Project files/a'b"}
	if config != expected {
		t.Fatalf("got %#v, want %#v", config, expected)
	}
	if !strings.Contains(output.String(), "Enter a hostname or IP address") {
		t.Fatal("invalid host did not prompt for correction")
	}

	reader = bufio.NewReader(strings.NewReader("Example.NET\n\n\n\n"))
	config, err = promptConnection(reader, io.Discard, "LocalUser")
	if err != nil || config != (connection{host: "example.net", username: "LocalUser", port: 22}) {
		t.Fatalf("defaults: %#v, %v", config, err)
	}
}

func TestRejectUnsafeConnectionInput(t *testing.T) {
	for _, value := range []string{"", "-host", "host;command", "user@host'quote", "user@@host", "[example.net]", "host:65536", "fe80::1%bad;zone"} {
		if _, _, _, err := parseAddress(value); err == nil {
			t.Errorf("accepted unsafe host %q", value)
		}
	}
	for _, value := range []string{"relative/folder", "~other", "/line\nbreak", "/invalid\xff", "/" + strings.Repeat("x", 4096)} {
		if err := validateDirectory(value); err == nil {
			t.Errorf("accepted unsafe directory")
		}
	}
}

func TestSSHArgumentsAndBootstrap(t *testing.T) {
	config := connection{host: "example.net", username: "dev", port: 2022, directory: "~/Report files/a'b"}
	args := sshArguments(config, "codex-preview-fixture")
	joined := strings.Join(args, "\n")
	for _, expected := range []string{
		"StrictHostKeyChecking=ask", "BatchMode=no", "ExitOnForwardFailure=yes",
		"-T\n-x", "ForwardAgent=no", "GatewayPorts=no", "PermitLocalCommand=no", "RemoteCommand=none",
		"ControlMaster=no", "ControlPath=none", "-L\n127.0.0.1:8877:/tmp/codex-preview-fixture/http.sock",
		"-L\n127.0.0.1:8878:/tmp/codex-preview-fixture/http.sock", "--\nexample.net",
	} {
		if !strings.Contains(joined, expected) {
			t.Errorf("missing %q from arguments", expected)
		}
	}
	command := args[len(args)-1]
	if strings.Contains(command, config.directory) || len(command) >= 8192 ||
		!strings.Contains(command, base64.StdEncoding.EncodeToString([]byte(config.directory))) {
		t.Fatal("remote bootstrap must be short and contain only encoded directory text")
	}
	line, err := encodeSource(previewSource)
	if err != nil {
		t.Fatal(err)
	}
	if len(line) > sourceLineMax || line[len(line)-1] != '\n' || bytes.Count(line, []byte{'\n'}) != 1 {
		t.Fatal("preview source must be one bounded LF-terminated line")
	}
	compressed, err := base64.StdEncoding.DecodeString(string(line[:len(line)-1]))
	if err != nil {
		t.Fatal(err)
	}
	zip, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatal(err)
	}
	defer zip.Close()
	source, err := io.ReadAll(zip)
	if err != nil || !bytes.Equal(source, previewSource) {
		t.Fatalf("embedded preview source did not round trip: %v", err)
	}
}

func TestSSHConsoleEnvironment(t *testing.T) {
	got := sshEnvironment([]string{"ssh_askpass=C:\\prompt.exe", "SSH_ASKPASS_REQUIRE=force", "SSH_ASKPASS_PROMPT=confirm", "SSH_AUTH_SOCK=agent"})
	if strings.Join(got, "\n") != "SSH_AUTH_SOCK=agent\nSSH_ASKPASS_REQUIRE=never" {
		t.Fatalf("unexpected SSH environment: %v", got)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) { return fn(request) }

func TestReadinessValidatesScopeAndSession(t *testing.T) {
	config := connection{host: "example.net", username: "dev", port: 22, directory: "~/reports"}
	files := health{
		Service: "codex-ssh-preview", Session: "codex-preview-fixture", Scope: "files",
		Target: config.target(), Port: config.port, Identity: "dev@server", RequestedDirectory: config.directory,
	}
	reports := files
	reports.Scope = "reports"
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/"+healthPath {
			t.Fatal("invalid readiness URL")
		}
		value := files
		if request.URL.Host == reportsAddress {
			value = reports
		} else if request.URL.Host != filesAddress {
			t.Fatal("readiness request left the loopback preview origins")
		}
		body, err := json.Marshal(value)
		if err != nil {
			return nil, err
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(body))}, nil
	})}
	ctx := context.Background()
	if _, ok := readyConnection(ctx, client, config, files.Session); !ok {
		t.Fatal("rejected matching connection")
	}
	if _, ok := readyConnection(ctx, client, config, "codex-preview-different"); ok {
		t.Fatal("accepted the wrong session for a new launch")
	}
	reports.RequestedDirectory = "~/other"
	if _, ok := readyConnection(ctx, client, config, ""); ok {
		t.Fatal("accepted a mismatched remote directory")
	}
	reports.RequestedDirectory = config.directory
	reports.Scope = "files"
	if _, ok := readyConnection(ctx, client, config, ""); ok {
		t.Fatal("accepted a mismatched scope")
	}
	reports.Scope = "reports"
	reports.Session = "codex-preview-different"
	if _, ok := readyConnection(ctx, client, config, ""); ok {
		t.Fatal("accepted mismatched sessions between ports")
	}
}
