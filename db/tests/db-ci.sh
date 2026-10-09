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
  docker rm -fv "$RUN_ID" >/dev/null 2>&1 || true
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

# Everything a second update could change: the changesets recorded (id and checksum, in the order they ran),
# the collections of the domain and the indexes of each. It always prints, so a failing mongosh is an error and
# never an empty string that two failed reads would share.
state() {
  mongo "const control = ['databasechangelog_identity_audit', 'databasechangeloglock_identity_audit'];
    const rows = db.getCollection('databasechangelog_identity_audit').find({}, {id: 1, md5sum: 1}).sort({orderExecuted: 1}).toArray();
    const data = db.getCollectionNames().filter(n => !control.includes(n) && !n.startsWith('system.')).sort();
    print('changesets=' + rows.map(r => r.id + '@' + r.md5sum).join(',') + ' collections=' + data.map(n => n + '[' + db.getCollection(n).getIndexes().map(i => i.name).sort().join('|') + ']').join(','))"
}

second_update_changes_nothing() {
  before=$(state) || { echo "could not read the state"; return 1; }
  out=$(lb update 2>&1) || { printf '%s\n' "$out" | tail -n 8; return 1; }
  after=$(state) || { echo "could not read the state"; return 1; }
  case $before in changesets=*) ;; *) echo "unexpected state: $before"; return 1 ;; esac
  [ "$before" = "$after" ] || { echo "the second update changed the database"; echo "  before: $before"; echo "  after:  $after"; return 1; }
}

# Nothing of the domain may be left: only the two control collections and the system ones
rolled_back_to_empty() {
  out=$(lb rollback-count 999 2>&1) || { printf '%s\n' "$out" | tail -n 8; echo "rollback-count 999 failed"; return 1; }
  now=$(state) || { echo "could not read the state"; return 1; }
  case $now in "changesets= collections=") ;; *) echo "the rollback left something: $now"; return 1 ;; esac
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
