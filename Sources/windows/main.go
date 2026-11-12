package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

//go:embed preview_server.py
var previewSource []byte

var version = "dev"

const (
	filesAddress   = "127.0.0.1:8878"
	reportsAddress = "127.0.0.1:8877"
	filesURL       = "http://" + filesAddress + "/"
	reportsURL     = "http://" + reportsAddress + "/"
	healthPath     = ".codex-preview/health"
	sourceLineMax  = 2 * 1024 * 1024
	healthBodyMax  = 64 * 1024
)

var (
	usernamePattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$`)
	hostPattern     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9_-]{0,62})*\.?$`)
	zonePattern     = regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)
	portPattern     = regexp.MustCompile(`^[0-9]{1,5}$`)
)

type connection struct {
	host      string
	username  string
	port      int
	directory string
}

func (c connection) target() string { return c.username + "@" + c.host }

func main() {
	if len(os.Args) > 1 {
		switch {
		case len(os.Args) == 2 && os.Args[1] == "--version":
			fmt.Println("Server Files " + version)
			return
		case len(os.Args) == 2 && os.Args[1] == "--help":
			fmt.Println("Run ServerFiles.exe without arguments to connect to a server over SSH.")
			return
		default:
			fmt.Fprintln(os.Stderr, "Usage: ServerFiles.exe [--help | --version]")
			os.Exit(2)
		}
	}

	reader := bufio.NewReader(os.Stdin)
	err := run(reader, os.Stdout)
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, io.EOF) {
		fmt.Fprintln(os.Stderr, "\n"+err.Error())
		fmt.Fprint(os.Stdout, "Press Enter to close. ")
		_, _ = reader.ReadString('\n')
		os.Exit(1)
	}
}

func run(reader *bufio.Reader, output io.Writer) error {
	ssh, err := systemOpenSSH()
	if err != nil {
		return err
	}
	fmt.Fprintln(output, "Server Files "+version)
	config, err := promptConnection(reader, output, os.Getenv("USERNAME"))
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	client := newHealthClient()
	if _, ok := readyConnection(ctx, client, config, ""); ok {
		fmt.Fprintln(output, "Opening the existing Server Files connection.")
		showFiles(output)
		return nil
	}
	if portInUse(filesAddress) || portInUse(reportsAddress) {
		return errors.New("Port 8877 or 8878 is already in use. Stop the existing preview and try again.")
	}
	fmt.Fprintf(output, "\nConnecting to %s on port %d.\n", config.target(), config.port)
	fmt.Fprintln(output, "Follow the OpenSSH prompts in this window. Press Ctrl+C to disconnect.")
	return startTunnel(ctx, ssh, client, config, output)
}

func promptConnection(reader *bufio.Reader, output io.Writer, defaultUser string) (connection, error) {
	var config connection
	var inferredUser string
	inferredPort := 22
	_, err := ask(reader, output, "SSH host or user@host", "", true, func(value string) error {
		var err error
		config.host, inferredUser, inferredPort, err = parseAddress(value)
		return err
	})
	if err != nil {
		return config, err
	}
	if inferredUser != "" {
		defaultUser = inferredUser
	} else if !usernamePattern.MatchString(defaultUser) {
		defaultUser = ""
	}
	config.username, err = ask(reader, output, "SSH username", defaultUser, true, validateUsername)
	if err != nil {
		return config, err
	}
	_, err = ask(reader, output, "SSH port", strconv.Itoa(inferredPort), true, func(value string) error {
		var err error
		config.port, err = parsePort(value)
		return err
	})
	if err != nil {
		return config, err
	}
	config.directory, err = ask(reader, output, "Remote folder (Enter for home)", "", false, validateDirectory)
	return config, err
}

func ask(reader *bufio.Reader, output io.Writer, label, fallback string, trim bool, validate func(string) error) (string, error) {
	for {
		if fallback != "" {
			fmt.Fprintf(output, "%s [%s]: ", label, fallback)
		} else {
			fmt.Fprintf(output, "%s: ", label)
		}
		line, readErr := reader.ReadString('\n')
		if readErr != nil && (len(line) == 0 || !errors.Is(readErr, io.EOF)) {
			return "", readErr
		}
		value := strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		if trim {
			value = strings.TrimSpace(value)
		}
		if value == "" {
			value = fallback
		}
		if err := validate(value); err != nil {
			fmt.Fprintln(output, err)
			if readErr != nil {
				return "", err
			}
			continue
		}
		return value, nil
	}
}

func validateUsername(value string) error {
	if !usernamePattern.MatchString(value) {
		return errors.New("Enter an SSH username using letters, digits, underscores, periods or hyphens.")
	}
	return nil
}

func parsePort(value string) (int, error) {
	port, err := strconv.Atoi(value)
	if !portPattern.MatchString(value) || err != nil || port < 1 || port > 65535 {
		return 0, errors.New("Enter an SSH port from 1 to 65535.")
	}
	return port, nil
}

func parseAddress(value string) (host, username string, port int, err error) {
	invalid := errors.New("Enter a hostname or IP address, optionally as user@host.")
	port = 22
	host = value
	if user, address, ok := strings.Cut(value, "@"); ok {
		if err = validateUsername(user); err != nil {
			return "", "", 0, err
		}
		host, username = address, user
	}
	if strings.HasPrefix(host, "[") {
		end := strings.IndexByte(host, ']')
		if end < 0 {
			return "", "", 0, invalid
		}
		address, remainder := host[1:end], host[end+1:]
		if !strings.Contains(address, ":") || (remainder != "" && !strings.HasPrefix(remainder, ":")) {
			return "", "", 0, invalid
		}
		host = address
		if remainder != "" {
			port, err = parsePort(remainder[1:])
		}
	} else if strings.Count(host, ":") == 1 {
		address, service, _ := strings.Cut(host, ":")
		host = address
		port, err = parsePort(service)
	}
	if err != nil {
		return "", "", 0, err
	}
	if strings.Contains(host, ":") {
		address, parseErr := netip.ParseAddr(host)
		if parseErr != nil || !address.Is6() || (address.Zone() != "" && !zonePattern.MatchString(address.Zone())) {
			return "", "", 0, invalid
		}
		base, zone, hasZone := strings.Cut(host, "%")
		host = strings.ToLower(base)
		if hasZone {
			host += "%" + zone
		}
	} else if len(host) <= 254 && hostPattern.MatchString(host) {
		host = strings.ToLower(host)
	} else {
		return "", "", 0, invalid
	}
	return host, username, port, nil
}

func validateDirectory(value string) error {
	if len(value) > 4096 || !utf8.ValidString(value) || strings.ContainsFunc(value, func(r rune) bool {
		return r < 32 || r == 127
	}) {
		return errors.New("Enter a UTF-8 path of up to 4096 bytes without control characters.")
	}
	if value != "" && !strings.HasPrefix(value, "/") && !strings.HasPrefix(value, "~/") {
		return errors.New("Start the remote folder with / or ~/, or leave it blank.")
	}
	return nil
}

func systemOpenSSH() (string, error) {
	if runtime.GOOS != "windows" {
		return "", errors.New("Run this launcher on Windows.")
	}
	path := filepath.Join(os.Getenv("SystemRoot"), "System32", "OpenSSH", "ssh.exe")
	if filepath.IsAbs(path) {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
			return path, nil
		}
	}
	return "", errors.New("Windows OpenSSH Client is unavailable. Enable OpenSSH Client in Optional Features and try again.")
}

func showFiles(output io.Writer) {
	fmt.Fprintln(output, "Files:   "+filesURL)
	fmt.Fprintln(output, "Reports: "+reportsURL)
	opener := filepath.Join(os.Getenv("SystemRoot"), "System32", "rundll32.exe")
	if !filepath.IsAbs(opener) {
		return
	}
	command := exec.Command(opener, "url.dll,FileProtocolHandler", filesURL)
	if err := command.Start(); err != nil {
		fmt.Fprintln(output, "Open the Files address above in your browser.")
		return
	}
	go func() { _ = command.Wait() }()
}

func encodeSource(source []byte) ([]byte, error) {
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(source); err != nil {
		_ = writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	length := base64.StdEncoding.EncodedLen(compressed.Len())
	if length+1 > sourceLineMax {
		return nil, errors.New("The embedded preview server exceeds the SSH bootstrap limit.")
	}
	line := make([]byte, length+1)
	base64.StdEncoding.Encode(line[:length], compressed.Bytes())
	line[length] = '\n'
	return line, nil
}

func newSession() (string, error) {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	return "codex-preview-" + hex.EncodeToString(random[:]), nil
}

func sshArguments(config connection, session string) []string {
	socketPath := "/tmp/" + session + "/http.sock"
	directory := base64.StdEncoding.EncodeToString([]byte(config.directory))
	// Only validated host/account data and ASCII base64 enter the remote command.
	// The Python source is sent on stdin to avoid Windows command-line length limits.
	command := fmt.Sprintf(
		"exec python3 -u -c 'import base64,gzip,sys;exec(gzip.decompress(base64.b64decode(sys.stdin.buffer.readline(%d).strip(),validate=True)))' '%s' '%s' '%s' '%d'",
		sourceLineMax, socketPath, directory, config.target(), config.port,
	)
	return []string{
		"-T", "-x", "-l", config.username, "-p", strconv.Itoa(config.port),
		"-o", "StrictHostKeyChecking=ask", "-o", "BatchMode=no",
		"-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=12",
		"-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
		"-o", "ForwardAgent=no", "-o", "GatewayPorts=no",
		"-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none",
		"-o", "ControlMaster=no", "-o", "ControlPath=none",
		"-L", reportsAddress + ":" + socketPath, "-L", filesAddress + ":" + socketPath,
		"--", config.host, command,
	}
}

func sshEnvironment(environment []string) []string {
	result := make([]string, 0, len(environment)+1)
	for _, pair := range environment {
		key, _, _ := strings.Cut(pair, "=")
		switch strings.ToUpper(key) {
		case "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "SSH_ASKPASS_PROMPT":
			continue
		}
		result = append(result, pair)
	}
	return append(result, "SSH_ASKPASS_REQUIRE=never")
}

type health struct {
	Service            string `json:"service"`
	Session            string `json:"session"`
	Scope              string `json:"scope"`
	Target             string `json:"target"`
	Port               int    `json:"port"`
	Identity           string `json:"identity"`
	RequestedDirectory string `json:"requested_directory"`
}

func newHealthClient() *http.Client {
	return &http.Client{
		Timeout:       900 * time.Millisecond,
		Transport:     &http.Transport{DisableKeepAlives: true},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

func readHealth(ctx context.Context, client *http.Client, rootURL, scope string, config connection) (health, bool) {
	var data health
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rootURL+healthPath, nil)
	if err != nil {
		return data, false
	}
	response, err := client.Do(request)
	if err != nil {
		return data, false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return data, false
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, healthBodyMax+1))
	if err != nil || len(body) > healthBodyMax || json.Unmarshal(body, &data) != nil {
		return data, false
	}
	valid := data.Service == "codex-ssh-preview" && data.Scope == scope &&
		strings.HasPrefix(data.Session, "codex-preview-") && data.Identity != "" &&
		data.Target == config.target() && data.Port == config.port && data.RequestedDirectory == config.directory
	return data, valid
}

func readyConnection(ctx context.Context, client *http.Client, config connection, expectedSession string) (health, bool) {
	files, ok := readHealth(ctx, client, filesURL, "files", config)
	if !ok || (expectedSession != "" && files.Session != expectedSession) {
		return health{}, false
	}
	reports, ok := readHealth(ctx, client, reportsURL, "reports", config)
	if !ok || reports.Session != files.Session || reports.Identity != files.Identity {
		return health{}, false
	}
	return files, true
}

func portInUse(address string) bool {
	connection, err := net.DialTimeout("tcp4", address, 200*time.Millisecond)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

func startTunnel(ctx context.Context, ssh string, client *http.Client, config connection, output io.Writer) error {
	session, err := newSession()
	if err != nil {
		return err
	}
	payload, err := encodeSource(previewSource)
	if err != nil {
		return err
	}
	command := exec.Command(ssh, sshArguments(config, session)...)
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	command.Env = sshEnvironment(os.Environ())
	input, err := command.StdinPipe()
	if err != nil {
		return err
	}
	if err := command.Start(); err != nil {
		_ = input.Close()
		return fmt.Errorf("Could not start OpenSSH: %w", err)
	}

	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	written := make(chan error, 1)
	go func() {
		_, err := io.Copy(input, bytes.NewReader(payload))
		written <- err
	}()
	finished := false
	defer func() {
		if finished {
			return
		}
		// Closing stdin can otherwise wait on a Windows pipe blocked during authentication.
		go func() { _ = input.Close() }()
		select {
		case <-exited:
		case <-time.After(3 * time.Second):
			_ = command.Process.Kill()
			<-exited
		}
	}()

	timer := time.NewTimer(2 * time.Minute)
	defer timer.Stop()
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()
	ready := ticker.C
	startupDeadline := timer.C
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-exited:
			finished = true
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				return fmt.Errorf("SSH connection ended: %w. If this host requires a VPN, connect it and try again", err)
			}
			return errors.New("SSH connection closed.")
		case err := <-written:
			written = nil
			if err != nil {
				return fmt.Errorf("Could not send the preview server over SSH: %w", err)
			}
		case <-startupDeadline:
			return errors.New("The preview did not start within two minutes. Check the SSH prompts and connect the VPN if the host requires it.")
		case <-ready:
			if info, ok := readyConnection(ctx, client, config, session); ok {
				fmt.Fprintln(output, "Connected to "+info.Identity+". Keep this window open while browsing.")
				showFiles(output)
				timer.Stop()
				ticker.Stop()
				startupDeadline = nil
				ready = nil
			}
		}
	}
}
