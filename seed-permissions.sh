#!/bin/bash

set -e

# =============================================================================
#  seed-permissions.sh
#
#  Seeds the Permissions collection for a single database.
#  Use seed-permissions-all.sh to run across all databases at once.
#
#  Requirements: mongosh
#
#  USAGE:
#    ./seed-permissions.sh --config configs/blocks-os.conf
#    ./seed-permissions.sh --config configs/blocks-os.conf --database MyDb
# =============================================================================

# =============================================================================
# DEFAULTS
# =============================================================================

MONGO_URI="${MONGO_URI:-mongodb://user:pass@host:27017/?authSource=admin}"
#MONGO_URI="mongodb://localhost:27017/"
DATABASE="c41adb333a894eb799a090fb6e0793cd"
COLLECTION="Permissions"
CREATED_BY="d122aced-623c-4ab2-a99f-40c6b0dbba4c"
CONFIG_FILE=""

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)     CONFIG_FILE="$2";   shift 2 ;;
    --mongo-uri)  MONGO_URI="$2";     shift 2 ;;
    --database)   DATABASE="$2";      shift 2 ;;
    --created-by) CREATED_BY="$2";    shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# =============================================================================
# VALIDATE & LOAD CONFIG
# =============================================================================

if [[ -z "$CONFIG_FILE" ]]; then
  echo "ERROR: --config is required."
  echo "       Example: ./seed-permissions.sh --config configs/blocks-os.conf"
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
echo "  Permissions Seed — Single Database"
echo "======================================="
echo "  Config      : $CONFIG_FILE"
echo "  Service     : $SERVICE_NAME"
echo "  Base URL    : $BASE_URL"
echo "  Version     : $VERSION"
echo "  Database    : $DATABASE"
echo "  Collection  : $COLLECTION"
echo "  Endpoints   : ${#ENDPOINTS[@]}"
echo "======================================="
echo ""

# =============================================================================
# BUILD JS buildDocs() FUNCTION
# =============================================================================

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

JS_DOCS_FN="
function buildDocs(createdBy) {
  const now = new Date('$NOW_ISO');
  const defaultRoles = ['project_admin', 'role', 'admin', 'cloudadmin'];
  const endpoints = ["

for ENTRY in "${ENDPOINTS[@]}"; do
  IFS='|' read -r CONTROLLER ACTION HTTP_METHOD <<< "$ENTRY"
  ROUTE=$(echo "$CONTROLLER" | tr '[:upper:]' '[:lower:]')
  ACTION_L=$(echo "$ACTION"  | tr '[:upper:]' '[:lower:]' | tr -d '.-')
  NAME="${SERVICE_NAME}::${ROUTE}::${ACTION_L}"
  RESOURCE="${SERVICE_NAME}::${ROUTE}::${ACTION_L}"
  JS_DOCS_FN+="
    { name: '$NAME', resource: '$RESOURCE', httpMethod: '$HTTP_METHOD' },"
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
    Roles:                ['project_admin', 'role', 'admin', 'cloudadmin'],
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
# SEED
# =============================================================================

RESULT=$(mongosh "$MONGO_URI" --quiet --eval "
  $JS_DOCS_FN

  const col      = db.getSiblingDB('$DATABASE').getCollection('$COLLECTION');
  const docs     = buildDocs('$CREATED_BY');
  let inserted   = 0;
  let skipped    = 0;

  docs.forEach(doc => {
    const exists = col.findOne({ Resource: doc.Resource }, { _id: 1 });
    if (exists) {
      print('  SKIP (exists) : ' + doc.Resource);
      skipped++;
    } else {
      col.insertOne(doc);
      print('  INSERTED      : ' + doc.Resource);
      inserted++;
    }
  });

  print('__RESULT__:' + inserted + ':' + skipped);
")

echo "$RESULT" | grep -v '__RESULT__'

COUNTS=$(echo "$RESULT" | grep '__RESULT__' | tail -1)
INS=$(echo "$COUNTS" | cut -d: -f2)
SKP=$(echo "$COUNTS" | cut -d: -f3)

echo ""
echo "======================================="
echo "  Service   : $SERVICE_NAME"
echo "  Database  : $DATABASE"
echo "  Inserted  : ${INS:-0}"
echo "  Skipped   : ${SKP:-0}"
echo "  Total     : ${#ENDPOINTS[@]}"
echo "======================================="