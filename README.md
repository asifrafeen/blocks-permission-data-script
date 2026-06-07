# blocks-permission-data-script

Bash tooling to seed and back up **permission** documents across MongoDB databases
for Blocks services. Endpoints are defined per service in simple `.conf` files and
seeded idempotently (existing resources are skipped).

## Requirements

- `bash`
- [`mongosh`](https://www.mongodb.com/docs/mongodb-shell/) (MongoDB Shell)

## Configuration

The MongoDB connection string is read from the `MONGO_URI` environment variable.
**No credentials are stored in this repo** — export your own before running:

```bash
export MONGO_URI="mongodb://user:pass@host:27017/?authSource=admin"
```

If `MONGO_URI` is unset the scripts fall back to a non-functional placeholder.

Each service has a config file under [`configs/`](configs/) describing its
endpoints. To add a new service, copy the template:

```bash
cp blocks-template.conf configs/blocks-MYSERVICE.conf
# then fill in SERVICE_NAME, BASE_URL, VERSION and the ENDPOINTS list
```

Endpoint format: `"Controller|ActionMethod|HttpMethod"` where `HttpMethod` is one
of `GET | POST | PUT | PATCH | DELETE`.

## Usage

```bash
# 1. Back up everything first (skip if a backup already exists)
./backup-permissions.sh

# 2. Seed all databases that contain a Permissions collection
./seed-permissions-all.sh --config configs/blocks-os.conf

# Target a single database instead
./seed-permissions.sh --config configs/blocks-os.conf --database BlocksRootDb
```

### Optional overrides

```bash
--mongo-uri  "mongodb://user:pass@host:27017/?authSource=admin"
--created-by <uuid>
--skip-dbs   "dbName1 dbName2"   # space-separated, added to defaults
```

## Scripts

| Script | Purpose |
| ------ | ------- |
| `backup-permissions.sh`     | Snapshot existing `Permissions` collections before changes. |
| `seed-permissions-all.sh`   | Seed a service config across every database with a `Permissions` collection. |
| `seed-permissions.sh`       | Seed a service config into a single database. |
| `blocks-template.conf`      | Template for defining a new service's endpoints. |

See [Workflow.txt](Workflow.txt) for the quick command reference.
