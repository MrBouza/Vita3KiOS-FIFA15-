# Hinoki ad hoc relay

Lets PS Vita games' **ad hoc** (local wireless) multiplayer work over the internet. Each player's
Hinoki connects to this server; the server puts players of the same game and room together and
passes their ad hoc traffic between them. It's one small Python file with no dependencies.

## Run it (Docker)

```sh
cd tools/adhoc-relay
docker compose up -d --build
docker logs -f hinoki-relay      # shows players joining and leaving
```

Without Docker: `python3 relay.py` (Python 3.8+).

Settings (environment variables in `docker-compose.yml`):

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_PORT` | `27360` | TCP port |
| `RELAY_KEY` | empty | If set, players must enter this key in Hinoki |
| `RELAY_MAX_ROOM` | `8` | Players per room |
| `RELAY_MAX_CLIENTS` | `64` | Players on the server |
| `RELAY_RATE` | `1000000` | Bytes per second per player |

## Let friends reach it

Pick one:

- **Tailscale (friends only, nothing opened on your router):** install Tailscale on the server
  and on every player's phone. Players use the server's Tailscale IP (`100.x.y.z`) in Hinoki.
- **Port forward (anyone with the address):** forward **TCP 27360** on your router to the
  server. Use a DDNS name (e.g. DuckDNS) because home IPs change, and set `RELAY_KEY`.
  Doesn't work if your ISP uses CGNAT; use Tailscale or a small VPS then.

The server only forwards traffic between players in the same room; it never runs anything it
receives. The container runs as a normal user with a read-only filesystem.

## In Hinoki

Settings › **Ad hoc multiplayer**:

1. Turn on **Ad hoc over the internet**.
2. **Server:** the address, e.g. `myserver.duckdns.org` or `100.101.102.103`
   (add `:port` if it isn't 27360).
3. **Room:** any word you and your friends agree on (empty = `public`). Only players running the
   same game in the same room see each other.
4. **Key:** only if the server sets `RELAY_KEY`.

Then start the game's ad hoc mode as usual on both phones. The status line in Settings and
`vita3k.log` show the connection, the other players and the ping.

## Notes

- Everything goes through the server, so latency is roughly player A → server → player B.
  Host it close to one of the players (or between them).
- Games were made for Vitas next to each other. Co-op games cope with internet latency much
  better than fast one-on-one games.
- Regions: the room includes the game's title ID, so players need the same version (e.g. both
  US, both `PCSE…`).
- `sceNetAdhocMatching` isn't implemented in the emulator yet. Games that use it for their lobby
  will log `sceNetAdhocMatching… unimplemented` and won't find each other yet.

Protocol: [PROTOCOL.md](PROTOCOL.md).
