#!/bin/sh
# I·db_ci_builds_reruns_rolls_back_and_rebuilds (RN-IDA-DB-08) and, as the collections arrive, the probes of
# the rules RN-IDA-DB-01 to -07 of the spec of HU-IDA-001.
#
# Builds the database `identity_audit` from an EMPTY MongoDB, applies the migrations a second time (nothing
# changes), rolls everything back (empty again) and applies them once more (Annex B, Annex J, J.6). It starts
# its own throwaway MongoDB, a one-node replica set as Annex B asks, and its own Liquibase runner image, on a
# private network that nothing else can reach, so it writes no secret and touches nothing else. Docker is the
# only requirement; the CI and a developer run this same file.
set -u
cd "$(dirname "$0")/../.." || exit 1

# Git Bash on Windows rewrites container paths such as /workspace; no effect elsewhere
export MSYS_NO_PATHCONV=1

MONGO_IMAGE="mongo:8.0.32"
RUN_ID="idadb-dbci-$$"
DB="identity_audit"
# the same image the runner of deploy/compose.yml uses: Liquibase plus the MongoDB extension and its driver
LIQUIBASE_IMAGE="$RUN_ID-liquibase"
fail=0

cleanup() {
  docker rm -f "$RUN_ID" >/dev/null 2>&1 || true
  docker network rm "$RUN_ID" >/dev/null 2>&1 || true
  docker rmi "$LIQUIBASE_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# mongosh in the throwaway container; the database has no user because nothing outside the private network can reach it
mongo() { docker exec "$RUN_ID" mongosh --quiet "$DB" --eval "$1"; }

# Its own control collections, so two domains never share one (Annex J, J.6)
lb() {
  docker run --rm --network "$RUN_ID" -v "$PWD:/workspace:ro" "$LIQUIBASE_IMAGE" \
    --search-path=/workspace --changelog-file=changelog/changelog-master.yaml \
    --url="mongodb://$RUN_ID:27017/$DB?directConnection=true" \
    --database-changelog-table-name=databasechangelog_identity_audit \
    --database-changelog-lock-table-name=databasechangeloglock_identity_audit "$@"
}

check() { # name, then the command that must succeed
  name=$1; shift
  if reason=$("$@" 2>&1); then
    echo "PASS  $name"
  else
    echo "FAIL  $name"
    printf '%s\n' "$reason" | tail -n 8 | sed 's/^/        /'
    fail=1
  fi
}

# The state of the control collection, so a second update that applied anything shows as a difference
changelog_state() {
  mongo "const rows = db.databasechangelog_identity_audit.find({}, {id: 1, md5sum: 1}).sort({orderexecuted: 1}).toArray(); print(rows.length + ':' + rows.map(r => r.id + r.md5sum).join(','))"
}

second_update_changes_nothing() {
  before=$(changelog_state)
  out=$(lb update 2>&1) || { printf '%s\n' "$out" | tail -n 8; return 1; }
  [ "$before" = "$(changelog_state)" ] || { echo "the second update changed the control collection"; return 1; }
}

# Nothing of the domain may be left: only the control collections of Liquibase and the system ones
domain_collections() {
  mongo "print(db.getCollectionNames().filter(n => !n.startsWith('databasechangelog') && !n.startsWith('system.')).sort().join(','))"
}

rolled_back_to_empty() {
  lb rollback-count 999 >/dev/null 2>&1 || { echo "rollback-count 999 failed"; return 1; }
  left=$(domain_collections)
  [ -z "$left" ] || { echo "the rollback left collections: $left"; return 1; }
}

# ---- an empty instance, as multi-tour-infra-mongo leaves it for this domain
docker build -q -f deploy/liquibase.Dockerfile -t "$LIQUIBASE_IMAGE" deploy >/dev/null || { echo "the runner image did not build"; exit 1; }
docker network create "$RUN_ID" >/dev/null || exit 1
docker run -d --name "$RUN_ID" --network "$RUN_ID" "$MONGO_IMAGE" --replSet rs0 --bind_ip_all >/dev/null || exit 1
ready=0
for _ in $(seq 1 60); do
  if docker exec "$RUN_ID" mongosh --quiet --eval "db.hello().ok" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "the throwaway MongoDB did not start"; exit 1; }
docker exec "$RUN_ID" mongosh --quiet --eval "rs.initiate({_id: 'rs0', members: [{_id: 0, host: '$RUN_ID:27017'}]})" >/dev/null || { echo "the replica set did not initiate"; exit 1; }
primary=0
for _ in $(seq 1 60); do
  [ "$(docker exec "$RUN_ID" mongosh --quiet --eval "db.hello().isWritablePrimary" 2>/dev/null)" = "true" ] && { primary=1; break; }
  sleep 1
done
[ "$primary" = 1 ] || { echo "the replica set never had a primary"; exit 1; }

check "I·db_ci_builds_from_empty" lb update
check "I·db_ci_second_update_changes_nothing" second_update_changes_nothing
check "I·db_ci_rolls_back_to_empty" rolled_back_to_empty
check "I·db_ci_rebuilds_after_the_rollback" lb update

# the single name the spec uses for the whole sequence (RN-IDA-DB-08)
[ "$fail" = 0 ] && echo "PASS  I·db_ci_builds_reruns_rolls_back_and_rebuilds"
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
