# Named Cloudflare Tunnel — activation guide

Quick tunnels give a new random `*.trycloudflare.com` URL on every restart
(audit H-1). A **named tunnel** gives fixed hostnames forever, which deletes
the endpoints.json publishing machinery, the git auto-commits, and most of
the watchdog's work. The code side is already built
(`cloudflared/config.example.yml`, `scripts/run_named_tunnel.sh`,
`TUNNEL_MODE=named` in `start_services.sh` / the watchdog). Activation needs
YOUR Cloudflare account and a domain — it cannot be done from code.

## Prerequisites
- A domain whose DNS is on Cloudflare (a domain costs roughly ₹800/yr; the
  Cloudflare account itself is free).
- `cloudflared` on the phone: the **Termux package** (`pkg install tur-repo
  && pkg install cloudflared`). Do NOT use Cloudflare's linux-arm64 binary
  in Termux — it is built for glibc and will not run under Android's bionic
  libc (it does run inside PRoot Ubuntu).

## Steps (on the phone, in Termux)
```bash
cloudflared tunnel login            # opens a browser auth flow, once
cloudflared tunnel create cloudhost # note the TUNNEL-UUID it prints
cloudflared tunnel route dns cloudhost nifty.example.com
cloudflared tunnel route dns cloudhost avatar.example.com
cloudflared tunnel route dns cloudhost host.example.com
# replace example.com with your domain, in the 3 commands above
mkdir -p ~/.cloudflared
cp cloudflared/config.example.yml ~/.cloudflared/config.yml
# edit config.yml: set tunnel UUID, credentials-file path, your hostnames
chmod 600 ~/.cloudflared/*.json     # credentials: never commit these
```

## Switch the host to named mode
```bash
export TUNNEL_MODE=named            # or set it in scripts/local.env
bash scripts/install.sh
bash scripts/start_services.sh      # starts ONE tunnel-named window
```
In named mode the watchdog logs `named mode: fixed hostnames` and skips
endpoint publishing entirely. The portal keeps working: set the two service
URLs in `endpoints.json` to the fixed hostnames once (and set
`window.PORTAL_CONFIGURED_DOMAIN` in the portal pages, or rely on the
hosts being edited into `assets/portal-common.js` CONFIGURED_DOMAIN), and
optionally add `host_daemon_url` pointing at the host hostname.

## Recommended: Cloudflare Access
Put Cloudflare Access (Zero Trust, free tier) in front of `host.` and
`avatar.` hostnames so the daemon and console require your login at the
edge — on top of the daemon's own `X-Host-Token` check for actions.
