// The C interface of go/zbwg (wireguard-go in user space + a local SOCKS5
// proxy), built by CI as a static library for iOS. Included by the app's
// bridging header (ZBAdblock.h).
#ifndef ZBWireGuard_h
#define ZBWireGuard_h

/// Brings up a tunnel from a WireGuard config (text) and a SOCKS5 proxy on
/// 127.0.0.1 that asks for user/pass. Returns the proxy port, or -1.
int zbwg_start(char * _Nonnull config, char * _Nonnull user, char * _Nonnull pass);
void zbwg_stop(void);

/// 1 when `host` resolves through the tunnel within timeoutMs, else 0.
int zbwg_check(char * _Nonnull host, int timeoutMs);

/// Seconds since the last handshake, or -1 when none.
long long zbwg_last_handshake(void);

/// The last error; free with zbwg_free.
char * _Nullable zbwg_last_error(void);
void zbwg_free(char * _Nullable text);

#endif
