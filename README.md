# Pritunl Slack Integration (Docker)

Polls DNS hostnames (ALBs, NLBs, etc.) for IP changes, updates Pritunl VPN route entries in MongoDB, and restarts OpenVPN — with Slack interactive approval flow.

## Quick Start

### 1. Create Configuration Files

**config.json:**

```json
{
  "server_name": "CloudKeeper",
  "slack_webhook": "https://hooks.slack.com/services/T00/B00/xxx",
  "slack_signing_secret": "your_slack_signing_secret",
  "openvpn_restart_cmd": "sudo systemctl restart pritunl",
  "restart_mode": "openvpn_only",
  "nat": true,
  "mongodb_uri": "mongodb://mongodb:27017",
  "mongodb_db": "pritunl",
  "pending_file": "/tmp/pending_routes.json",
  "port": 5001
}
```

**hostnames.json:**

```json
[
  "my-alb-1.us-east-1.elb.amazonaws.com"
]
```

### 2. Run with Docker Compose

```bash
docker compose up -d
```

The container runs both the webhook server (port 5001) and the poller (every 10s) together.

### 3. Slack App Configuration

1. Go to https://api.slack.com/apps → Create New App
2. **Slash Commands** → Create New Command
   - Command: `/routes`
   - Request URL: `https://your-endpoint/slack/command`
3. **Interactivity** → Set Request URL to `https://your-endpoint/slack/interactive`
4. **Basic Information** → copy **Signing Secret** → add to `config.json` as `slack_signing_secret`
5. Install the app to your workspace

## Docker Setup

### Prerequisites

- Docker & Docker Compose
- Access to the Pritunl MongoDB instance
- (Optional) Slack incoming webhook URL
- Privileged access on the Pritunl host if this container should restart OpenVPN/Pritunl automatically

### Running with Docker Compose

```yaml
services:
  pritunl-slack:
    build: .
    container_name: pritunl-slack
    restart: unless-stopped
    ports:
      - "5001:5001"
    # Required only when this container should restart host OpenVPN/Pritunl.
    # This grants broad host process access; omit it if restarts are handled externally.
    pid: host
    privileged: true
    environment:
      - CONFIG_PATH=/app/config.json
      - MONGODB_URI=mongodb://host.docker.internal:27017
      - SLACK_WEBHOOK_URL=
      - POLLER_INTERVAL=10
    volumes:
      - ./config.json:/app/config.json:ro
      - ./hostnames.json:/app/hostnames.json
      - pending_data:/tmp
```

`hostnames.json` must be writable for `/routes watch`, `/routes unwatch`, and rejected hostname changes. If you omit `pid: host` or `privileged: true`, route updates can still be written to MongoDB, but automatic OpenVPN/Pritunl restart will not be able to signal host processes.

### Running with Docker Run (privileged)

For OpenVPN restart to work, the container needs host PID namespace and permission to signal host processes.

If MongoDB is bound to `127.0.0.1` on the host (common for Pritunl), use `--network=host` so the container's `localhost` maps to the host's loopback. With `--network=host`, `MONGODB_URI` should use `localhost` and port mapping (`-p`) is not needed — the app listens on the host's IP directly.

```bash
docker run -d --name pritunl-slack \
  --network=host \
  --pid=host \
  --privileged \
  -v /proc:/proc:ro \
  -v $(pwd)/config.json:/app/config.json:ro \
  -v $(pwd)/hostnames.json:/app/hostnames.json \
  -v /var/log/pritunl-docker:/var/log/pritunl-docker \
  -e MONGODB_URI="mongodb://localhost:27017" \
  pritunl-slack
```

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CONFIG_PATH` | `/app/config.json` | Path to config file inside container |
| `MONGODB_URI` | `mongodb://host.docker.internal:27017` | MongoDB connection string |
| `SLACK_WEBHOOK_URL` | `""` | Slack incoming webhook URL |
| `POLLER_INTERVAL` | `10` | Poller loop interval in seconds |
| `LOG_DIR` | `/var/log/pritunl-docker` | Directory for Python script logs (route-updater.log, webhook-server.log) |
| `OPENVPN_RESTART_CMD` | `sudo systemctl restart pritunl` | Restart command used when config does not set `openvpn_restart_cmd` |

### Building the Image

```bash
docker build -t pritunl-slack .
```

### Start on System Boot

This repo includes a systemd unit that recreates the `pritunl-slack:2.4` container after Docker starts. The unit expects the repo files at `/root/pritunl-slack-integration-docker`:

```bash
sudo cp systemd/pritunl-slack.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable pritunl-slack.service
sudo systemctl start pritunl-slack.service
```

Check status and logs:

```bash
sudo systemctl status pritunl-slack.service
docker logs pritunl-slack
```

If the service fails to start, check whether the bind-mount files exist on the host:

```bash
sudo test -f /root/pritunl-slack-integration-docker/config.json
sudo test -f /root/pritunl-slack-integration-docker/hostnames.json
```

## How It Works

1. Reads tracked hostnames from `hostnames.json`
2. For each hostname, resolves DNS to current IPs
3. Compares with existing routes in MongoDB (matched by `comment: "dns:<hostname>"`)
4. If any hostname's IPs changed, saves only the changed entries to `pending_routes.json` and sends an interactive Slack message with **Approve** / **Reject** buttons
5. Clicking **Approve** merges the pending routes into MongoDB (replaces old routes for each changed hostname, appends new ones), restarts OpenVPN/Pritunl, and removes the pending file
6. Duplicate or stale Approve/Reject callbacks are ignored after the pending file has already been handled, so they do not overwrite the successful Slack message
7. Clicking **Reject** removes the pending file **and unwatch the rejected hostnames** from `hostnames.json` — the poller stops tracking them
8. Only routes matching tracked hostnames are touched — other routes are left intact
9. If changes match what's already pending, the poller re-sends the notification instead of creating duplicates
10. Direct Slack route mutations (`/routes add`, `/routes delete`, and route-removing `/routes unwatch`) update MongoDB and trigger the configured restart path immediately

## Configuration

### config.json

| Key | Required | Description |
|---|---|---|
| `server_name` | Yes | Pritunl server name (matches `name` in MongoDB `servers`) |
| `slack_webhook` | No | Slack incoming webhook URL (or `SLACK_WEBHOOK_URL` env var) |
| `slack_signing_secret` | No | Slack app signing secret (verifies requests) |
| `restart_mode` | No | `"openvpn_only"` (kill child, Pritunl respawns) or `"full"` (systemctl restart) |
| `openvpn_restart_cmd` | No | Full restart fallback command |
| `nat` | No | Enable NAT on routes (default: `true`) |
| `mongodb_uri` | No | Default: `mongodb://localhost:27017` (or `MONGODB_URI` env var) |
| `mongodb_db` | No | Default: `pritunl` |
| `pending_file` | No | Path for pending route changes (default: `/tmp/pending_routes.json`) |
| `port` | No | Flask listen port (default: `5001`) |
| `slack_channel_id` | No | Restrict Slack commands/interactions to this channel ID only |

### hostnames.json

```json
[
  "my-alb-1.us-east-1.elb.amazonaws.com",
  "my-alb-2.us-east-1.elb.amazonaws.com"
]
```

## Restart Mode

Pritunl manages OpenVPN as a child process. The `restart_mode` field controls how routes are applied. Restarts are triggered after approved DNS route changes and after direct Slack route mutations that change MongoDB routes.

**`openvpn_only` (default):**
1. Kills the OpenVPN child process(es) with SIGTERM
2. Pritunl detects the process died and respawns it with the updated config
3. If OpenVPN doesn't respawn within 3 seconds, falls back to full `systemctl restart pritunl`

**`full`:**
1. Runs `systemctl restart pritunl` directly
2. Longer downtime but more direct than killing OpenVPN children

If logs show `No Pritunl parent process found`, `No OpenVPN child process was killed`, or permission errors, the container cannot see or signal the host Pritunl/OpenVPN process. Run with host PID access and sufficient privileges, or set `restart_mode` to `full` with an `openvpn_restart_cmd` that works from inside the container.

## API Endpoints

### Routes (MongoDB)

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/routes` | List all routes |
| `POST` | `/api/routes` | Add a route |
| `PUT` | `/api/routes/<network>` | Update a route |
| `DELETE` | `/api/routes/<network>` | Delete a route |
| `POST` | `/api/restart` | Trigger OpenVPN restart |

### Hostnames (hostnames.json)

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/hostnames` | List tracked hostnames |
| `POST` | `/api/hostnames` | Add a hostname |
| `DELETE` | `/api/hostnames` | Remove a hostname |

## Slack Commands

```
/routes list              — show all routes
/routes add 10.0.0.0/16   — add a route and trigger restart
/routes delete 10.0.0.0/16 — delete a route and trigger restart
/routes hostnames          — list tracked hostnames
/routes watch my-alb.elb.amazonaws.com    — start tracking; poller creates pending routes for approval
/routes unwatch my-alb.elb.amazonaws.com  — stop tracking, remove routes, and trigger restart when routes were removed
```

> **Approve/Reject:** When IPs change, the poller sends an interactive message. **Approve** merges the new routes into MongoDB. **Reject** removes the hostname from `hostnames.json` so the poller stops tracking it.

> Input is sanitised automatically — backticks, asterisks, underscores, quotes, and `https://` prefixes are stripped so you can paste hostnames directly from Slack messages without worrying about formatting.

## Logging

All logs are written to `/var/log/pritunl-docker/` on the host (mount this volume when running the container).

```bash
# Poller logs
tail -f /var/log/pritunl-docker/route-updater.log

# Webhook server logs
tail -f /var/log/pritunl-docker/webhook-access.log
tail -f /var/log/pritunl-docker/webhook-error.log
```

## Verification

```bash
# Test the webhook server
curl http://localhost:5001/api/routes

# Check routes in MongoDB
mongosh pritunl --eval 'db.servers.findOne({name:"CloudKeeper"}, {routes:1}).pretty()'

# Check iptables
sudo iptables -t nat -L POSTROUTING -n -v | grep <new_ip>
```
