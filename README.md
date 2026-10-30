# UniFi OS Server for Docker &amp; Kubernetes

<a href="https://github.com/Ozark-Connect/unifi-os-server/pkgs/container/unifi-os-server"><img src="https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fgithub.com%2FOzark-Connect%2Funifi-os-server%2Fpkgs%2Fcontainer%2Funifi-os-server&search=(%3Fs)%3Cspan%5B%5E%3E%5D*%3E%5Cs*Total%5Cs%2Bdownloads%5Cs*%3C%2Fspan%3E.*%3F%3Ch3%5B%5E%3E%5D*%3E%5Cs*(%5B0-9%5D%5B0-9.%2C%5D*%5Cs*%5BKM%5D%3F)%5Cs*%3C%2Fh3%3E&replace=%241&logo=github&label=Downloads&cacheSeconds=3600"></a>
<a href="https://github.com/Ozark-Connect/unifi-os-server/actions/workflows/build-image.yaml"><img src="https://img.shields.io/github/actions/workflow/status/Ozark-Connect/unifi-os-server/build-image.yaml?logo=githubactions&logoColor=white&label=Actions"></a>

Run [UniFi OS Server](https://blog.ui.com/article/introducing-unifi-os-server) directly in Docker or Kubernetes.

> **This is the [Ozark-Connect](https://github.com/Ozark-Connect) community fork** of [`lemker/unifi-os-server`](https://github.com/lemker/unifi-os-server), maintained to stay current with Ubiquiti's releases — **including Early Access (EA) builds** — with image tags kept in lockstep with the official UniFi OS Server versions. New stable and EA versions are picked up automatically from Ubiquiti's firmware API.

> The **UniFi OS Server is the new standard for self-hosting UniFi**, replacing the legacy UniFi Network Server. While the Network Server provided basic hosting functionality, it lacked support for key UniFi OS features like Organizations, IdP Integration, or Site Magic SD-WAN. With a fully unified operating system, UniFi OS Server now delivers the same management experience as UniFi-native–including CloudKeys, Cloud Gateways, and Official UniFi Hosting–and is fully compatible with Site Manager for centralized, multi-site control.
>
> <https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi>

# Installation

## Image Tags

Tags match the official UniFi OS Server version exactly — no separate scheme:

| Tag | Channel | Notes |
|----|----|----|
| `latest` · `X.Y.Z` · `X.Y` · `X` | Stable | Newest stable release |
| `X.Y.Z-ea` | Early Access | Pre-release; never tagged `latest` |
| `X.Y.Z-N` | Fork patch | An Ozark-Connect fix on top of UniFi `X.Y.Z` |

```bash
docker pull ghcr.io/ozark-connect/unifi-os-server:latest      # newest stable
docker pull ghcr.io/ozark-connect/unifi-os-server:5.1.21-ea   # a specific EA build
```

## Docker Compose

See [docker-compose.yaml](https://github.com/Ozark-Connect/unifi-os-server/blob/main/docker-compose.yaml)

## Discovery

UniFi OS Server does not scan the network from inside its container. UniFi Core asks a helper on the host, `uos-discovery-client`, at `host.docker.internal:11002`, and the helper sends UniFi discovery (UDP 10001) out of the host's interfaces. Ubiquiti's installer runs it on the host; this image ships the same binary at `/usr/local/bin/uos-discovery`, and the compose file runs it as the `unifi-os-server-discovery` service with `network_mode: host`.

Without it, UniFi OS Server discovers no consoles and no unadopted devices, and features that depend on discovery (direct-connect DNS records for other consoles on the LAN, console stacking) do not work.

- **Required with it:** `extra_hosts: host.docker.internal: host-gateway` on the main service (already in the compose file).
- **`DISCOVERY_CLIENT_SERVER_HOST`** is the only address the helper's API listens on. Set it to the address `host.docker.internal` resolves to, the `docker0` gateway (`172.17.0.1` unless you changed Docker's `bip`). Do not use `0.0.0.0`: that exposes the API to your LAN.
- **Do not publish UDP 10001 from the main container.** The helper binds `0.0.0.0:10001` on the host for its passive listener.
- **UDP 10003 must answer on the host's `127.0.0.1`.** The passive listener forwards what it hears to `127.0.0.1:10003`. The compose file publishes 10003 on every address; if you bind it to one IP instead, also publish `127.0.0.1:10003:10003/udp`.
- **Subnets:** discovery is broadcast and multicast, so it reaches only the subnets the host has an interface on. The helper uses every host interface automatically. To discover a console or device on another VLAN, give the host an interface (for example a VLAN sub-interface) on it; otherwise adopt with `set-inform` as below.
- **Host firewall:** a reply to a discovery broadcast is a new connection to conntrack, not an established one. If your host drops new inbound traffic on an interface, allow UDP from source port 10001 to the ephemeral ports there, for example `iptables -I INPUT -i <iface> -p udp --sport 10001 --dport 32768:60999 -j ACCEPT`.
- **Kubernetes:** the manifests do not include the helper yet. Run the same image with `hostNetwork: true` and the `uos-discovery` entrypoint on the node, and point `host.docker.internal` at that node.

## Direct connect to UniFi OS Server itself

The UniFi mobile app connects to a console on the LAN at `https://<console-id>.id.ui.direct` on port 443, and falls back to Ubiquiti's cloud relay when that fails. Hardware consoles register that name; UniFi OS Server never does, and in Docker it reports itself with the container's MAC, so the gateway never creates a record for it either. The discovery helper does not change that.

The fix is a local DNS override for that name plus a reverse proxy that bridges port 443 to the server's 11443. Self-signed certificates are fine. Full walkthrough: [uos-server-mobile-direct](https://github.com/Ozark-Connect/uos-server-mobile-direct).

Your console ID is in the container:

```bash
docker exec unifi-os-server cat /data/unifi-core/config/http/direct-connect-domain.conf
# server_name <console-id>.id.ui.direct;
```

## Kubernetes

See [kubernetes](https://github.com/Ozark-Connect/unifi-os-server/tree/main/kubernetes)

Deployment example uses [ingress-nginx](https://github.com/kubernetes/ingress-nginx) for the ingress and [longhorn](https://github.com/longhorn/longhorn) for storage.

Your ingress controller must be modified to accept extra ports. For example, `ingress-nginx` Helm values:

```yaml
tcp:
  5005: "unifi/unifi-os-server-rtp-svc:5005" # Optional
  9543: "unifi/unifi-os-server-id-hub-svc:9543" # Optional
  6789: "unifi/unifi-os-server-mobile-speedtest-svc:6789" # Optional
  8080: "unifi/unifi-os-server-communication-svc:8080"
  8444: "unifi/unifi-os-server-hotspot-secured-svc:8444" # Optional
  28082: "unifi/unifi-os-server-support-files:28082" # Optional
  5671: "unifi/unifi-os-server-aqmps-svc:5671" # Optional
  8880: "unifi/unifi-os-server-hotspot-redirect-0-svc:8880" # Optional
  8881: "unifi/unifi-os-server-hotspot-redirect-1-svc:8881" # Optional
  8882: "unifi/unifi-os-server-hotspot-redirect-2-svc:8882" # Optional
udp:
  3478: "unifi/unifi-os-server-stun-svc:3478"
  5514: "unifi/unifi-os-server-syslog-svc:5514" # Optional
  10003: "unifi/unifi-os-server-discovery-svc:10003"
```

# Parameters

## Environment Variables

| Environment | Description |
|----|----|
| UOS_SYSTEM_IP | Hostname or IP for UniFi OS Server |
| HARDWARE_PLATFORM | Manually set hardware platform |
| UOS_TRUSTED_PROXIES | Reverse proxy addresses to take the client IP from |
| UOS_FEATURES_LOOP_PATCH | Set to `false` to disable the UniFi Core features-loop patch |

### UOS_SYSTEM_IP

Set UniFi OS Server hostname (recommended) or IP address for inform. To adopt device:

1. SSH into device with username/password: `ubnt`/`ubnt`
2. Set inform address:

   ```bash
   set-inform http://$UOS_SYSTEM_IP:8080/inform
   ```

### HARDWARE_PLATFORM

Overrides your detected hardware platform. Accepted values are: `synology`.

### UOS_TRUSTED_PROXIES

Behind a reverse proxy (Traefik, Caddy, nginx), the audit log and the System Log record the proxy's address for every login and access, not the client's. Set `UOS_TRUSTED_PROXIES` to the addresses or CIDRs your proxy connects from, separated by commas or spaces. nginx in the container then takes the client IP from the proxy's `X-Forwarded-For` header on requests from those addresses only.

```yaml
environment:
  - UOS_TRUSTED_PROXIES=172.24.0.1
```

- **Which address:** the source IP nginx sees, not the proxy's LAN IP. Check the `ip=` field in `/data/unifi-core/logs/nginx-access.log`. A proxy on the host network that connects to a published port arrives from the gateway of the container's Docker network.
- **Pin that network's subnet.** Docker picks the subnet when it creates the network, so a `docker compose down` can move the gateway. nginx then sees an address it does not trust and logs the proxy again. Pin it in your compose file and trust the gateway:

  ```yaml
  networks:
    default:
      ipam:
        config:
          - subnet: 172.24.0.0/16
            gateway: 172.24.0.1
  ```
- **Proxy chains:** if your proxy forwards a client IP from an upstream proxy (for example Cloudflare), list that proxy's ranges too.
- **Trust only your proxy.** Any address in the list can set an arbitrary client IP.
- **Unset:** no change from stock behavior.

### UOS_FEATURES_LOOP_PATCH

Network 11.0.81 through 11.0.97 and UniFi Core call each other in a loop: Network refreshes its system info through core `GET /api/system`, and core answers by fetching Network's features, which calls core again. The loop fills Network's connection pool to core, and most of the Network API stalls for 40 s several times a day.

The container patches core's features fetch to serve the last value and refresh it in the background, so `/api/system` never waits on Network.

- **Version-gated:** the patch applies only while the installed Network is in the affected range. On any other version, or if the stock function is not found, the stock `service.js` is restored. A Network update that fixes the loop removes the patch without an image update.
- **In-app updates:** a watcher re-checks every 30 s after a Network or `unifi-core` update and restarts `unifi-core` when it changes `service.js`.
- **Check:** `docker exec unifi-os-server grep -c uos-features-loop-patch /usr/share/unifi-core/app/service.js` prints `1` when patched.
- **`false`:** restores the stock `service.js` on the next start.

## Ports

| Protocol | Port | Direction | Usage |
|----|----|----|----|
| TCP | 11443 | Ingress | UniFi OS Server GUI/API |
| TCP | 5005 | Ingress | RTP (Real-time Transport Protocol) control protocol |
| TCP | 9543 | Ingress | UniFi Identity Hub |
| TCP | 6789 | Ingress | UniFi mobile speed test |
| TCP | 8080 | Ingress | Device and application communication |
| TCP | 8444 | Ingress | Secure Portal for Hotspot |
| UDP | 3478 | Both | STUN for device adoption and communication *(also required for Remote Management)* |
| UDP | 5514 | Ingress | Remote syslog capture |
| UDP | 10003 | Ingress | Device discovery during adoption |
| UDP | 10001 | Both | UniFi discovery, on the host through the discovery helper (see [Discovery](#discovery)); not published from the container |
| TCP | 28082 | Ingress | Device support files download |
| TCP | 5671 | Ingress | AQMPS |
| TCP | 8880 | Ingress | Hotspot portal redirection (HTTP) |
| TCP | 8881 | Ingress | Hotspot portal redirection (HTTP) |
| TCP | 8882 | Ingress | Hotspot portal redirection (HTTP) |

# Frequently Asked Questions

## What is the difference between images?

The `uosserver` image is provided by UniFi, extracted from the installation binary, with the installer's discovery helper added at `/usr/local/bin/uos-discovery`. The `unifi-os-server` image provides better compatibility for Docker and Kubernetes with directory fixes and configuration through environment variables.

## Why does the container need specific settings for cgroup and tmpfs?

The underlying structure of UniFi OS Server runs every component as systemd services which requires access to the host `cgroup`.

---

<sub>UniFi OS Server for Docker &amp; Kubernetes is an independent project by Ozark Connect and is not affiliated with, endorsed by, or sponsored by Ubiquiti, Inc. Ubiquiti, UniFi, and UniFi OS are trademarks or registered trademarks of Ubiquiti, Inc. All other trademarks are the property of their respective owners.</sub>