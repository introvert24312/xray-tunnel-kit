# Xray Tunnel Kit

Debian/Ubuntu installer for Xray VMess and VLESS over WebSocket behind Cloudflare Tunnel. Supports either an existing fixed (named) Tunnel or a temporary Cloudflare Quick Tunnel. It is an independent implementation inspired by the deployment pattern in [eooce/xray-2go](https://github.com/eooce/xray-2go).

## Port model

`ORIGIN_PORT` is the local HTTP port that Cloudflare Tunnel forwards to. It defaults to `10126`. Caddy listens only on loopback using the wildcard site address `http://:ORIGIN_PORT` plus `bind 127.0.0.1`, so it accepts the public hostname Cloudflare forwards in the Host header. It sends the two WebSocket paths to Xray listeners on the next two loopback ports:

- `ORIGIN_PORT + 1`: VLESS WS at `/vless-argo`
- `ORIGIN_PORT + 2`: VMess WS at `/vmess-argo`

For example, with `ORIGIN_PORT=10126`, Cloudflare forwards to `http://127.0.0.1:10126`; Xray listens privately on `10127` and `10128`. These ports are not exposed to the public network by this installer. No firewall rules are flushed or changed.

## Fixed Tunnel

Create a named Tunnel and a **Published application** route in Cloudflare. Point its service to `http://127.0.0.1:10126` (or your chosen origin port). Install/run the `cloudflared` connector as Cloudflare instructs. Then download the installer on the Debian/Ubuntu VPS:

```sh
curl -fsSLO https://raw.githubusercontent.com/introvert24312/xray-tunnel-kit/master/install.sh
chmod +x install.sh
TUNNEL_MODE=fixed DOMAIN=argo.example.com ORIGIN_PORT=10126 ./install.sh
```

If logging in as root, run directly; otherwise use `sudo env TUNNEL_MODE=fixed DOMAIN=... ORIGIN_PORT=... ./install.sh`.

The fixed Tunnel's Cloudflare route must target the Caddy origin port. The public client always uses port 443 with TLS; the local origin port (10126) is only between `cloudflared` and Caddy. The hostname should be a domain managed in your Cloudflare account.

## Move to a new VPS (fixed Tunnel)

For each new VPS:

1. Create or select a named Cloudflare Tunnel and connect `cloudflared` on the VPS.
2. Add a **Published application** route for the public hostname. Set its service to `http://127.0.0.1:<ORIGIN_PORT>` (for example, `http://127.0.0.1:10126`).
3. Download this repository's latest `install.sh` on the VPS.
4. Run the installer with the hostname and the same origin port used in the route:
   ```sh
   TUNNEL_MODE=fixed DOMAIN=your.hostname.example ORIGIN_PORT=10126 ./install.sh
   ```
5. Generate the client links:
   ```sh
   xray-tunnel-kit-links
   ```
   Import the VLESS and VMess links into your client.

The installer does not configure the Cloudflare Tunnel or handle its token. Choose an unused `ORIGIN_PORT`; the next two ports (`ORIGIN_PORT + 1` and `ORIGIN_PORT + 2`) must also be free for the loopback-only Xray listeners.

## Temporary Quick Tunnel

```sh
TUNNEL_MODE=quick ORIGIN_PORT=10126 ./install.sh
```

This starts its own systemd Quick Tunnel service. The temporary hostname can change after the connector restarts. Retrieve it with:

```sh
journalctl -u xray-tunnel-kit-cloudflared -n 50 --no-pager
```

Then generate fresh client links using the printed hostname:

```sh
xray-tunnel-kit-links YOUR-NAME.trycloudflare.com
```

## Client links and services

After fixed mode installation, generate both links with:

```sh
xray-tunnel-kit-links
```

Services:

```sh
systemctl status xray-tunnel-kit-xray caddy --no-pager
journalctl -u xray-tunnel-kit-xray -n 50 --no-pager
journalctl -u caddy -n 50 --no-pager
```

Use the VLESS or VMess link as appropriate. Both use TLS on the public hostname and WebSocket paths listed above. The generated VMess link uses `aes-128-gcm` for compatibility with sing-box and `alterId=0`. Cloudflare terminates public TLS; the local service is plain HTTP on loopback. For fixed mode, make sure the named Tunnel connector is healthy and the published route uses the exact local origin port.

## Optional settings

- `UUID`: set a client UUID yourself. Otherwise one is generated.
- `ORIGIN_PORT`: local Caddy origin port (default `10126`). The next two ports must also be available for private Xray listeners.

Example:

```sh
TUNNEL_MODE=fixed DOMAIN=argo.example.com ORIGIN_PORT=10126 UUID=00000000-0000-4000-8000-000000000001 ./install.sh
```

## Notes

- Run only on Debian or Ubuntu with systemd, as root.
- Fixed mode expects `cloudflared` to be installed and connected separately. The installer does not read, print, or store the Cloudflare Tunnel token.
- Quick mode uses a temporary `trycloudflare.com` hostname and does not need a token.
- The installer replaces `/etc/caddy/Caddyfile` and writes Xray config under `/etc/xray-tunnel-kit/`.
- It does not flush firewall rules or open public inbound ports.
- Keep generated client links private; they contain the UUID.
