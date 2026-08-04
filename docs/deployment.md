# Deploying the Splitcore server

## Run it

```bash
docker compose up -d
curl http://127.0.0.1:8090/api/health   # {"message":"API is healthy.","code":200,...}
```

The compose file binds **127.0.0.1 only**. Splitcore must not be exposed
directly: PocketBase speaks plain HTTP, and an auth token sent over HTTP
is a stolen auth token.

## First run

1. `docker compose exec server /app/splitcore-server superuser upsert you@example.com 'a-strong-password'`
2. Open the admin UI through your proxy at `/_/` and confirm the six
   collections exist (`groups`, `group_members`, `expenses`,
   `split_entries`, `settlements`, `balances`).

Migrations run automatically at container start (the entrypoint calls
`migrate up` before `serve`) — automigrate is off for compiled binaries,
which is why the explicit step exists.

## HTTPS

Terminate TLS at a reverse proxy. Caddy needs the least configuration
because it obtains and renews certificates itself:

```caddyfile
splitcore.example.com {
    reverse_proxy 127.0.0.1:8090

    # The admin UI should not be world-reachable.
    @admin path /_/*
    handle @admin {
        @notallowed not remote_ip 203.0.113.0/24
        respond @notallowed 403
        reverse_proxy 127.0.0.1:8090
    }
}
```

nginx equivalent: `proxy_pass http://127.0.0.1:8090;` plus
`proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` and
`client_max_body_size 10m` (receipt uploads).

Then point clients at it:

```bash
flutter build apk --dart-define=POCKETBASE_URL=https://splitcore.example.com
```

## Backups

Everything that matters is in the `pb_data` volume: the SQLite database
**and** every uploaded receipt image. Backing up the `.db` file alone
loses the receipts.

**Built-in (preferred).** PocketBase's admin UI → Settings → Backups
creates a consistent archive of the whole data directory while the server
runs, and can upload to S3. Enable a daily schedule there.

**From the host**, snapshot the volume:

```bash
docker run --rm \
  -v splitcore_pb_data:/data:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf "/backup/pb_data-$(date +%F-%H%M).tar.gz" -C /data .
```

The volume is named after the compose project directory — check the exact
name with `docker volume ls` (it is `slice_pay_pb_data` when the
repository directory is `slice_pay`).

Run it from cron. Keep at least 7 daily and 4 weekly copies, and store one
copy off the host — a backup on the same disk as the database is not a
backup.

## Restore

```bash
docker compose down
docker run --rm \
  -v splitcore_pb_data:/data \
  -v "$PWD/backups:/backup" \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/pb_data-2026-08-04-0300.tar.gz -C /data"
docker compose up -d
curl -fsS http://127.0.0.1:8090/api/health
```

**Rehearse a restore before you need one.** Restore into a throwaway
volume, start the server against it, and confirm you can sign in and see a
group. An unrehearsed backup is a guess.

## Monitoring

- **Liveness:** `GET /api/health` — already the container's health check.
- **Logs:** `docker compose logs -f server`. PocketBase logs every request;
  ship them to your aggregator via the Docker logging driver.
- **Disk:** receipts grow `pb_data` without bound. Alert at 80% full.
- **Backups:** alert when the newest archive is older than 48 hours. A
  backup job that silently stopped is the most common way data is lost.
