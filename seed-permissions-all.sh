#!/bin/bash

set -e

# Load .env (if present) from the script's directory so MONGO_URI etc. are set
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$_SCRIPT_DIR/.env"
  set +a
fi

# =============================================================================
#  seed-permissions-all.sh
#
#  Runs the permissions seed for a given service config across EVERY database
#  on the server that contains a Permissions collection.
#  Skips any Resource that already exists (idempotent).
#
#  Requirements: mongosh
#
#  USAGE:
#    ./seed-permissions-all.sh --config configs/blocks-os.conf
#
#  OPTIONAL OVERRIDES:
#    --mongo-uri  "mongodb://user:pass@host:27017/?authSource=admin"
#    --created-by <uuid>
#    --skip-dbs   "dbName1 dbName2"   (space-separated, added to defaults)
# =============================================================================

# =============================================================================
# DEFAULTS
# =============================================================================

MONGO_URI="${MONGO_URI:-mongodb://user:pass@host:27017/?authSource=admin}"
#MONGO_URI="mongodb://localhost:27017/"
COLLECTION="Permissions"
CREATED_BY="d122aced-623c-4ab2-a99f-40c6b0dbba4c"
SKIP_DBS=("admin" "config" "local")
CONFIG_FILE=""

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)     CONFIG_FILE="$2";              shift 2 ;;
    --mongo-uri)  MONGO_URI="$2";                shift 2 ;;
    --created-by) CREATED_BY="$2";               shift 2 ;;
    --skip-dbs)   IFS=' ' read -ra EXTRA <<< "$2"
                  SKIP_DBS+=("${EXTRA[@]}");     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# =============================================================================
# VALIDATE & LOAD CONFIG
# =============================================================================

if [[ -z "$CONFIG_FILE" ]]; then
  echo "ERROR: --config is required."
  echo "       Example: ./seed-permissions-all.sh --config configs/blocks-os.conf"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

for VAR in SERVICE_NAME BASE_URL VERSION; do
  if [[ -z "${!VAR}" ]]; then
    echo "ERROR: '$VAR' is not set in $CONFIG_FILE"
    exit 1
  fi
done

if [[ ${#ENDPOINTS[@]} -eq 0 ]]; then
  echo "ERROR: ENDPOINTS array is empty in $CONFIG_FILE"
  exit 1
fi

echo ""
echo "======================================="
echo "  Permissions Seed — All Databases"
echo "======================================="
echo "  Config      : $CONFIG_FILE"
echo "  Service     : $SERVICE_NAME"
echo "  Base URL    : $BASE_URL"
echo "  Version     : $VERSION"
echo "  Collection  : $COLLECTION"
echo "  Endpoints   : ${#ENDPOINTS[@]}"
echo "======================================="
echo ""

# =============================================================================
# HELPER — check if a value is in the skip list
# =============================================================================

function is_skipped() {
  local db="$1"
  for skip in "${SKIP_DBS[@]}"; do
    [[ "$db" == "$skip" ]] && return 0
  done
  return 1
}

# =============================================================================
# STEP 1 — discover all databases
# =============================================================================

echo "  Discovering databases..."

ALL_DBS=$(mongosh "$MONGO_URI" --quiet --eval \
  "db.adminCommand({ listDatabases: 1 }).databases.map(d => d.name).join('\n')")

if [[ -z "$ALL_DBS" ]]; then
  echo "  ERROR: Could not retrieve database list. Check connection."
  exit 1
fi

echo "  Connection: OK"
echo ""

# =============================================================================
# STEP 2 — filter databases that have a Permissions collection
# =============================================================================

TARGET_DBS=()

while IFS= read -r DB_NAME; do
  [[ -z "$DB_NAME" ]] && continue
  is_skipped "$DB_NAME" && continue

  HAS_COL=$(mongosh "$MONGO_URI" --quiet --eval "
    db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$COLLECTION');
  ")

  if [[ "$HAS_COL" == "true" ]]; then
    TARGET_DBS+=("$DB_NAME")
    echo "  FOUND   : $DB_NAME"
  else
    echo "  SKIP    : $DB_NAME (no $COLLECTION collection)"
  fi
done <<< "$ALL_DBS"

echo ""

if [[ ${#TARGET_DBS[@]} -eq 0 ]]; then
  echo "  No databases contain a '$COLLECTION' collection. Nothing to seed."
  exit 0
fi

echo "  Databases to seed: ${#TARGET_DBS[@]}"
echo ""

# =============================================================================
# STEP 3 — build the document array as a JS expression
#   Format per config line:  "Controller|Action|HttpMethod"
#   Generated Name/Resource: serviceName::controller::action  (all lowercase)
# =============================================================================

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

# Build JS array literal from ENDPOINTS array
JS_DOCS_FN="
function buildDocs(createdBy) {
  const now = new Date('$NOW_ISO');
  const defaultRoles = ['project_admin', 'role', 'admin', 'cloudadmin'];
  const endpoints = ["

for ENTRY in "${ENDPOINTS[@]}"; do
  IFS='|' read -r CONTROLLER ACTION HTTP_METHOD <<< "$ENTRY"
  ROUTE=$(echo "$CONTROLLER"    | tr '[:upper:]' '[:lower:]')
  ACTION_L=$(echo "$ACTION"     | tr '[:upper:]' '[:lower:]' | tr -d '.-')
  NAME="${SERVICE_NAME}::${ROUTE}::${ACTION_L}"
  RESOURCE="${SERVICE_NAME}::${ROUTE}::${ACTION_L}"
  JS_DOCS_FN+="
    { controller: '$CONTROLLER', action: '$ACTION', httpMethod: '$HTTP_METHOD', name: '$NAME', resource: '$RESOURCE' },"
done

JS_DOCS_FN+="
  ];

  return endpoints.map(ep => ({
    _id:                  crypto.randomUUID(),
    CreatedDate:          now,
    LastUpdatedDate:      now,
    CreatedBy:            createdBy,
    Language:             null,
    LastUpdatedBy:        createdBy,
    OrganizationIds:      [],
    Tags:                 [],
    Name:                 ep.name,
    Type:                 1,
    Description:          '',
    Resource:             ep.resource,
    ResourceGroup:        '$SERVICE_NAME',
    IsBuiltIn:            true,
    IsArchived:           false,
    DependentPermissions: [],
    Roles:                defaultRoles,
    UserId:               [],
    IsCaptchaRequired:    false,
    IsMFARequired:        false,
    MfaMediaType:         0,
    IsAllowed:            true,
    Limit:                0,
    Usage:                0,
    BaseUrl:              '$BASE_URL',
    Version:              '$VERSION',
    HttpMethod:           ep.httpMethod,
  }));
}
"

# =============================================================================
# STEP 4 — seed each database
# =============================================================================

GRAND_INSERTED=0
GRAND_SKIPPED=0
declare -A DB_INSERTED
declare -A DB_SKIPPED

for DB_NAME in "${TARGET_DBS[@]}"; do

  echo "  ── $DB_NAME ──"

  RESULT=$(mongosh "$MONGO_URI" --quiet --eval "
    $JS_DOCS_FN

    const db       = db.getSiblingDB('$DB_NAME');
    const col      = db.getCollection('$COLLECTION');
    const createdBy = '$CREATED_BY';
    const docs     = buildDocs(createdBy);

    let inserted = 0;
    let skipped  = 0;

    docs.forEach(doc => {
      const exists = col.findOne({ Resource: doc.Resource }, { _id: 1 });
      if (exists) {
        print('     SKIP (exists) : ' + doc.Resource);
        skipped++;
      } else {
        col.insertOne(doc);
        print('     INSERTED      : ' + doc.Resource);
        inserted++;
      }
    });

    print('__RESULT__:' + inserted + ':' + skipped);
  ")

  echo "$RESULT" | grep -v '__RESULT__'

  COUNTS=$(echo "$RESULT" | grep '__RESULT__' | tail -1)
  INS=$(echo "$COUNTS" | cut -d: -f2)
  SKP=$(echo "$COUNTS" | cut -d: -f3)

  DB_INSERTED[$DB_NAME]=${INS:-0}
  DB_SKIPPED[$DB_NAME]=${SKP:-0}
  GRAND_INSERTED=$((GRAND_INSERTED + ${INS:-0}))
  GRAND_SKIPPED=$((GRAND_SKIPPED + ${SKP:-0}))

  echo "     → inserted=${INS:-0}  skipped=${SKP:-0}"
  echo ""

done

# =============================================================================
# SUMMARY TABLE
# =============================================================================

echo "======================================="
echo "  Service           : $SERVICE_NAME"
echo "  Databases seeded  : ${#TARGET_DBS[@]}"
echo ""
printf "  %-30s %8s %8s\n" "Database" "Inserted" "Skipped"
printf "  %-30s %8s %8s\n" "------------------------------" "--------" "--------"
for DB_NAME in "${TARGET_DBS[@]}"; do
  printf "  %-30s %8s %8s\n" "$DB_NAME" "${DB_INSERTED[$DB_NAME]}" "${DB_SKIPPED[$DB_NAME]}"
done
printf "  %-30s %8s %8s\n" "------------------------------" "--------" "--------"
printf "  %-30s %8s %8s\n" "TOTAL" "$GRAND_INSERTED" "$GRAND_SKIPPED"
echo "======================================="