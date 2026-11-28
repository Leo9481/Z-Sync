// Package main is Z-Browser's browser-only VPN: a WireGuard client in user
// space (wireguard-go and its gVisor network stack, MIT) with a small SOCKS5
// proxy on 127.0.0.1 in front of it. WebKit is pointed at the proxy, so only
// the browser's traffic goes through the tunnel; the rest of the phone is
// untouched and no VPN entitlement is needed.
//
// Built by CI as a static library for iOS (-buildmode=c-archive). One tunnel
// at a time; every exported function is safe to call from any thread.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type tunnel struct {
	dev      *device.Device
	net      *netstack.Net
	listener net.Listener
	user     string
	pass     string
}

var (
	mu        sync.Mutex
	current   *tunnel
	lastError string
)

func fail(err error) C.int {
	lastError = err.Error()
	return -1
}

// zbwg_start brings up a tunnel from a WireGuard config (the text of a .conf
// file) and a SOCKS5 proxy on 127.0.0.1 that asks for user/pass. Returns the
// proxy's port, or -1 (see zbwg_last_error). A running tunnel is stopped first.
//
//export zbwg_start
func zbwg_start(config, user, pass *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
	lastError = ""

	cfg, err := parseConfig(C.GoString(config))
	if err != nil {
		return fail(err)
	}
	tunDev, tnet, err := netstack.CreateNetTUN(cfg.addresses, cfg.dns, 1420)
	if err != nil {
		return fail(fmt.Errorf("tunnel: %w", err))
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "zbwg: "))
	if err := dev.IpcSet(cfg.uapi); err != nil {
		dev.Close()
		return fail(fmt.Errorf("config: %w", err))
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return fail(fmt.Errorf("up: %w", err))
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		dev.Close()
		return fail(fmt.Errorf("proxy: %w", err))
	}
	t := &tunnel{dev: dev, net: tnet, listener: listener, user: C.GoString(user), pass: C.GoString(pass)}
	current = t
	go t.serve()
	return C.int(listener.Addr().(*net.TCPAddr).Port)
}

// zbwg_stop ends the tunnel and its proxy, if any.
//
//export zbwg_stop
func zbwg_stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if current == nil {
		return
	}
	current.listener.Close()
	current.dev.Close()
	current = nil
}

// zbwg_check proves the tunnel carries traffic: it looks up `host` through
// the tunnel's DNS within timeoutMs. 1 when it answered, 0 when not.
//
//export zbwg_check
func zbwg_check(host *C.char, timeoutMs C.int) C.int {
	mu.Lock()
	t := current
	mu.Unlock()
	if t == nil {
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	addrs, err := t.net.LookupContextHost(ctx, C.GoString(host))
	if err != nil || len(addrs) == 0 {
		mu.Lock()
		if err != nil {
			lastError = err.Error()
		} else {
			lastError = "no address"
		}
		mu.Unlock()
		return 0
	}
	return 1
}

// zbwg_last_handshake: seconds since the last handshake with the server, or
// -1 when there hasn't been one (or no tunnel).
//
//export zbwg_last_handshake
func zbwg_last_handshake() C.longlong {
	mu.Lock()
	t := current
	mu.Unlock()
	if t == nil {
		return -1
	}
	state, err := t.dev.IpcGet()
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(state, "\n") {
		if value, ok := strings.CutPrefix(line, "last_handshake_time_sec="); ok {
			seconds, err := strconv.ParseInt(value, 10, 64)
			if err != nil || seconds == 0 {
				return -1
			}
			return C.longlong(time.Now().Unix() - seconds)
		}
	}
	return -1
}

// zbwg_last_error: the last failure, as a C string to free with zbwg_free.
//
//export zbwg_last_error
func zbwg_last_error() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return C.CString(lastError)
}

//export zbwg_free
func zbwg_free(text *C.char) {
	C.free(unsafe.Pointer(text))
}

// MARK: - Config

type wgConfig struct {
	addresses []netip.Addr
	dns       []netip.Addr
	uapi      string
}

func keyHex(value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(raw) != 32 {
		return "", errors.New("a key isn't a WireGuard key")
	}
	return hex.EncodeToString(raw), nil
}

// parseConfig reads a wg-quick style config: [Interface] PrivateKey, Address,
// DNS; [Peer] PublicKey, PresharedKey, Endpoint, AllowedIPs,
// PersistentKeepalive. Other keys (MTU, PostUp, …) are ignored.
func parseConfig(text string) (*wgConfig, error) {
	cfg := &wgConfig{}
	var uapi strings.Builder
	section := ""
	sawPeer := false
	peerKeepalive := false
	endpointSet := false
	finishPeer := func() {
		if sawPeer && !peerKeepalive {
			// Keeps the tunnel (and the server's NAT entry) alive, and makes
			// the first handshake happen at once.
			uapi.WriteString("persistent_keepalive_interval=25\n")
		}
	}
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if i := strings.IndexAny(line, "#;"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[] "))
			if section == "peer" {
				finishPeer()
				sawPeer = true
				peerKeepalive = false
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		switch section {
		case "interface":
			switch key {
			case "privatekey":
				k, err := keyHex(value)
				if err != nil {
					return nil, err
				}
				uapi.WriteString("private_key=" + k + "\n")
			case "address":
				for _, part := range strings.Split(value, ",") {
					prefix, err := netip.ParsePrefix(strings.TrimSpace(part))
					if err != nil {
						addr, err2 := netip.ParseAddr(strings.TrimSpace(part))
						if err2 != nil {
							return nil, fmt.Errorf("address %q", part)
						}
						cfg.addresses = append(cfg.addresses, addr)
						continue
					}
					cfg.addresses = append(cfg.addresses, prefix.Addr())
				}
			case "dns":
				for _, part := range strings.Split(value, ",") {
					if addr, err := netip.ParseAddr(strings.TrimSpace(part)); err == nil {
						cfg.dns = append(cfg.dns, addr)
					}
				}
			}
		case "peer":
			switch key {
			case "publickey":
				k, err := keyHex(value)
				if err != nil {
					return nil, err
				}
				uapi.WriteString("public_key=" + k + "\n")
			case "presharedkey":
				k, err := keyHex(value)
				if err != nil {
					return nil, err
				}
				uapi.WriteString("preshared_key=" + k + "\n")
			case "endpoint":
				endpoint, err := resolveEndpoint(value)
				if err != nil {
					return nil, err
				}
				uapi.WriteString("endpoint=" + endpoint + "\n")
				endpointSet = true
			case "allowedips":
				for _, part := range strings.Split(value, ",") {
					if prefix, err := netip.ParsePrefix(strings.TrimSpace(part)); err == nil {
						uapi.WriteString("allowed_ip=" + prefix.String() + "\n")
					}
				}
			case "persistentkeepalive":
				if seconds, err := strconv.Atoi(value); err == nil && seconds > 0 {
					uapi.WriteString("persistent_keepalive_interval=" + strconv.Itoa(seconds) + "\n")
					peerKeepalive = true
				}
			}
		}
	}
	finishPeer()
	switch {
	case len(cfg.addresses) == 0:
		return nil, errors.New("the config has no Address")
	case !sawPeer || !endpointSet:
		return nil, errors.New("the config has no server (Peer Endpoint)")
	case len(cfg.dns) == 0:
		// No DNS of its own would send the browser's lookups outside the
		// tunnel; Proton's server answers on 10.2.0.1.
		return nil, errors.New("the config has no DNS")
	}
	cfg.uapi = uapi.String()
	return cfg, nil
}

// resolveEndpoint turns host:port into ip:port (WireGuard needs an address).
func resolveEndpoint(value string) (string, error) {
	host, port, err := net.SplitHostPort(value)
	if err != nil {
		return "", fmt.Errorf("endpoint %q", value)
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		return netip.AddrPortFrom(addr, mustPort(port)).String(), nil
	}
	ips, err := net.DefaultResolver.LookupNetIP(context.Background(), "ip4", host)
	if err != nil || len(ips) == 0 {
		return "", fmt.Errorf("server %q not found", host)
	}
	return netip.AddrPortFrom(ips[0], mustPort(port)).String(), nil
}

func mustPort(text string) uint16 {
	port, _ := strconv.Atoi(text)
	return uint16(port)
}

// MARK: - SOCKS5 (RFC 1928 CONNECT, RFC 1929 username/password)

func (t *tunnel) serve() {
	for {
		client, err := t.listener.Accept()
		if err != nil {
			return // closed
		}
		go t.handle(client)
	}
}

func (t *tunnel) handle(client net.Conn) {
	defer client.Close()
	client.SetDeadline(time.Now().Add(30 * time.Second))
	reader := bufio.NewReader(client)

	// Greeting: only username/password (0x02) is accepted.
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil || header[0] != 5 {
		return
	}
	methods := make([]byte, header[1])
	if _, err := io.ReadFull(reader, methods); err != nil {
		return
	}
	hasAuth := false
	for _, m := range methods {
		if m == 2 {
			hasAuth = true
		}
	}
	if !hasAuth {
		client.Write([]byte{5, 0xFF})
		return
	}
	client.Write([]byte{5, 2})

	// Username/password.
	authHeader := make([]byte, 2)
	if _, err := io.ReadFull(reader, authHeader); err != nil || authHeader[0] != 1 {
		return
	}
	user := make([]byte, authHeader[1])
	if _, err := io.ReadFull(reader, user); err != nil {
		return
	}
	passLength := make([]byte, 1)
	if _, err := io.ReadFull(reader, passLength); err != nil {
		return
	}
	pass := make([]byte, passLength[0])
	if _, err := io.ReadFull(reader, pass); err != nil {
		return
	}
	if string(user) != t.user || string(pass) != t.pass {
		client.Write([]byte{1, 1})
		return
	}
	client.Write([]byte{1, 0})

	// Request: CONNECT only.
	request := make([]byte, 4)
	if _, err := io.ReadFull(reader, request); err != nil || request[0] != 5 {
		return
	}
	if request[1] != 1 {
		client.Write([]byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	var host string
	switch request[3] {
	case 1:
		ip := make([]byte, 4)
		if _, err := io.ReadFull(reader, ip); err != nil {
			return
		}
		host = net.IP(ip).String()
	case 4:
		ip := make([]byte, 16)
		if _, err := io.ReadFull(reader, ip); err != nil {
			return
		}
		host = net.IP(ip).String()
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(reader, length); err != nil {
			return
		}
		name := make([]byte, length[0])
		if _, err := io.ReadFull(reader, name); err != nil {
			return
		}
		host = string(name)
	default:
		client.Write([]byte{5, 8, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(reader, portBytes); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(portBytes)

	// Names are looked up through the tunnel's DNS: nothing leaks outside.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	remote, err := t.net.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(int(port))))
	if err != nil {
		client.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	defer remote.Close()
	client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
	client.SetDeadline(time.Time{})

	done := make(chan struct{}, 2)
	go func() { io.Copy(remote, reader); done <- struct{}{} }()
	go func() { io.Copy(client, remote); done <- struct{}{} }()
	<-done
}

func main() {}
