# Xray Tunnel Kit

Debian/Ubuntu installer for Xray VMess and VLESS over WebSocket behind Cloudflare Tunnel. Supports either an existing fixed (named) Tunnel or a temporary Cloudflare Quick Tunnel. It is an independent implementation inspired by the deployment pattern in [eooce/xray-2go](https://github.com/eooce/xray-2go).

## Port model

`ORIGIN_PORT` is the local HTTP port that Cloudflare Tunnel forwards to. It defaults to `10126`. Caddy listens on `127.0.0.1:ORIGIN_PORT` and sends the two WebSocket paths to Xray listeners on the next two loopback ports:

- `ORIGIN_PORT + 1`: VLESS WS at `/vless-argo`
- `ORIGIN_PORT + 2`: VMess WS at `/vmess-argo`

For example, with `ORIGIN_PORT=10126`, Cloudflare forwards to `http://127.0.0.1:10126`; Xray listens privately on `10127` and `10128`. These ports are not exposed to the public network by this installer. No firewall rules are flushed or changed.

## Fixed Tunnel

Create a named Tunnel and a **Published application** route in Cloudflare. Point its service to `http://127.0.0.1:10126` (or your chosen origin port). Install/run the `cloudflared` connector as Cloudflare instructs. This repository is private, so first authorize an SSH key on the Debian/Ubuntu VPS for read access to this repository, then clone it:

```sh
git clone git@github.com:introvert24312/xray-tunnel-kit.git
cd xray-tunnel-kit
TUNNEL_MODE=fixed DOMAIN=argo.example.com ORIGIN_PORT=10126 ./install.sh
```

If logging in as root, run directly; otherwise use `sudo env TUNNEL_MODE=fixed DOMAIN=... ORIGIN_PORT=... ./install.sh`.

The fixed Tunnel's Cloudflare route must target the Caddy origin port. The public client always uses port 443 with TLS; the local origin port (10126) is only between `cloudflared` and Caddy. The hostname should be a domain managed in your Cloudflare account.

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

Use the VLESS or VMess link as appropriate. Both use TLS on the public hostname and WebSocket paths listed above. Cloudflare terminates public TLS; the local service is plain HTTP on loopback. For fixed mode, make sure the named Tunnel connector is healthy and the published route uses the exact local origin port.

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
