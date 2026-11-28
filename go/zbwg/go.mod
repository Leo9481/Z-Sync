module zbwg

go 1.24

// Pinned (the same wireguard-go revision wireproxy uses). CI runs
// `go mod tidy` against these pins to write go.sum before building.
require golang.zx2c4.com/wireguard v0.0.0-20250521234502-f333402bd9cb
