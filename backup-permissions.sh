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
#  backup-permissions.sh
#
#  For every database on the server that contains a Permissions collection:
#    1. Exports the collection to a JSON dump file via mongoexport
#    2. Creates  Permissions_Backup_YYYYMMDD  inside that same database
#
#  Requirements: mongosh, mongoexport (mongo-tools)
#
#  USAGE:
#    ./backup-permissions.sh
#    ./backup-permissions.sh --mongo-uri "mongodb://user:pass@host:27017/?authSource=admin"
#    ./backup-permissions.sh --backup-dir /data/backups
# =============================================================================

# =============================================================================
# DEFAULTS
# =============================================================================

MONGO_URI="${MONGO_URI:-mongodb://user:pass@host:27017/?authSource=admin}"
COLLECTION="Permissions"
SKIP_DBS=("admin" "config" "local")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups/permissions-$(date +%Y%m%d-%H%M%S)"
DATE_SUFFIX=$(date +%Y%m%d)
BACKUP_COL="${COLLECTION}_Backup_${DATE_SUFFIX}"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mongo-uri)   MONGO_URI="$2";   shift 2 ;;
    --backup-dir)  BACKUP_DIR="$2";  shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

mkdir -p "$BACKUP_DIR"

echo ""
echo "======================================="
echo "  Permissions Backup"
echo "======================================="
echo "  Mongo URI      : $MONGO_URI"
echo "  Collection     : $COLLECTION"
echo "  Backup Col     : $BACKUP_COL"
echo "  Backup Dir     : $BACKUP_DIR"
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
    db = db.getSiblingDB('$DB_NAME');
    db.getCollectionNames().includes('$COLLECTION');
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
  echo "  No databases contain a '$COLLECTION' collection. Nothing to do."
  exit 0
fi

echo "  Databases to back up: ${#TARGET_DBS[@]}"
echo ""

# =============================================================================
# STEP 3 — backup each database
# =============================================================================

TOTAL_BACKED=0

for DB_NAME in "${TARGET_DBS[@]}"; do

  echo "  ── $DB_NAME ──"

  # -- 3a. mongoexport JSON dump --
  DUMP_FILE="$BACKUP_DIR/${DB_NAME}__${COLLECTION}.json"

  mongoexport \
    --uri="$MONGO_URI" \
    --db="$DB_NAME" \
    --collection="$COLLECTION" \
    --out="$DUMP_FILE" \
    --jsonArray \
    --quiet

  DOC_COUNT=$(mongosh "$MONGO_URI" --quiet --eval "
    db.getSiblingDB('$DB_NAME')['$COLLECTION'].countDocuments()
  ")

  echo "     Dump   → $DUMP_FILE  ($DOC_COUNT docs)"

  # -- 3b. create backup collection inside same DB (server-side $out) --
  EXISTING=$(mongosh "$MONGO_URI" --quiet --eval "
    db.getSiblingDB('$DB_NAME').getCollectionNames().includes('$BACKUP_COL');
  ")

  if [[ "$EXISTING" == "true" ]]; then
    mongosh "$MONGO_URI" --quiet --eval "
      db.getSiblingDB('$DB_NAME')['$BACKUP_COL'].drop();
    "
    echo "     Dropped existing '$BACKUP_COL' (refreshing)"
  fi

  mongosh "$MONGO_URI" --quiet --eval "
    db = db.getSiblingDB('$DB_NAME');
    db['$COLLECTION'].aggregate([ { \$out: '$BACKUP_COL' } ]);
  "

  BACKED_COUNT=$(mongosh "$MONGO_URI" --quiet --eval "
    db.getSiblingDB('$DB_NAME')['$BACKUP_COL'].countDocuments()
  ")

  echo "     Backup → $BACKUP_COL  ($BACKED_COUNT docs)"

  # -- 3c. keep only latest 3 backup collections per DB --
  OLD_BACKUPS=$(mongosh "$MONGO_URI" --quiet --eval "
    db.getSiblingDB('$DB_NAME')
      .getCollectionNames()
      .filter(c => c.startsWith('${COLLECTION}_Backup_') && c !== '$BACKUP_COL')
      .sort()
      .join('\n');
  ")

  BACKUP_COUNT=0
  while IFS= read -r OLD_COL; do
    [[ -z "$OLD_COL" ]] && continue
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
  done <<< "$OLD_BACKUPS"

  if [[ $BACKUP_COUNT -ge 3 ]]; then
    REMOVE_COUNT=$((BACKUP_COUNT - 2))
    REMOVED=0
    while IFS= read -r OLD_COL; do
      [[ -z "$OLD_COL" ]] && continue
      [[ $REMOVED -ge $REMOVE_COUNT ]] && break
      mongosh "$MONGO_URI" --quiet --eval "
        db.getSiblingDB('$DB_NAME')['$OLD_COL'].drop();
      "
      echo "     Removed old backup: $OLD_COL"
      REMOVED=$((REMOVED + 1))
    done <<< "$OLD_BACKUPS"
  fi

  TOTAL_BACKED=$((TOTAL_BACKED + BACKED_COUNT))
  echo ""

done

# =============================================================================
# STEP 4 — write manifest
# =============================================================================

MANIFEST="$BACKUP_DIR/manifest.json"
{
  echo "{"
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"collection\": \"$COLLECTION\","
  echo "  \"backup_collection\": \"$BACKUP_COL\","
  echo "  \"backup_dir\": \"$BACKUP_DIR\","
  echo "  \"databases\": ["
  FIRST=true
  for DB_NAME in "${TARGET_DBS[@]}"; do
    $FIRST || echo "    ,"
    echo "    { \"database\": \"$DB_NAME\", \"dump_file\": \"$BACKUP_DIR/${DB_NAME}__${COLLECTION}.json\", \"backup_col\": \"$BACKUP_COL\" }"
    FIRST=false
  done
  echo "  ]"
  echo "}"
} > "$MANIFEST"

# =============================================================================
# SUMMARY
# =============================================================================

echo "======================================="
echo "  Databases processed : ${#TARGET_DBS[@]}"
echo "  Total docs backed   : $TOTAL_BACKED"
echo "  Backup collection   : $BACKUP_COL"
echo "  Dump directory      : $BACKUP_DIR"
echo "  Manifest            : $MANIFEST"
echo "======================================="