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

# Same versions from another registry when Docker Hub limits the address (the CI sets both; see db-ci.yml)
MONGO_IMAGE="${MONGO_IMAGE:-mongo:8.0.32}"
LIQUIBASE_BASE="${LIQUIBASE_BASE:-liquibase/liquibase:5.0.4}"
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

# Docker Hub limits the anonymous downloads of an address, and a shared CI runner can be over the limit
# (429 Too Many Requests): wait and try again before giving up. retry ATTEMPTS SECONDS COMMAND...
retry() {
  attempts=$1; wait=$2; shift 2
  tried=1
  until "$@"; do
    [ "$tried" -ge "$attempts" ] && return 1
    echo "download failed (attempt $tried of $attempts), waiting ${wait}s" >&2
    tried=$((tried + 1)); sleep "$wait"
  done
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
    print('changesets=' + rows.map(r => r.id + '@' + r.md5sum).join(',') + ' collections=' + data.map(n => n + '[' + db.getCollection(n).getIndexes().map(i => i.name).sort().join('|') + ']' + JSON.stringify(db.getCollectionInfos({name: n})[0].options)).join(','))"
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

# Idempotence of each changeset (plan D-08): if the control collections are lost, or a run stopped half way,
# running again must leave the database as it was and must not fail on what already exists
migration_is_idempotent_when_the_control_is_lost() {
  before=$(state) || { echo "could not read the state"; return 1; }
  mongo "db.databasechangelog_identity_audit.drop(); db.databasechangeloglock_identity_audit.drop()" >/dev/null || { echo "could not drop the control collections"; return 1; }
  out=$(lb update 2>&1) || { printf '%s\n' "$out" | tail -n 8; return 1; }
  after=$(state) || { echo "could not read the state"; return 1; }
  [ "$before" = "$after" ] || { echo "the run changed the database"; echo "  before: $before"; echo "  after:  $after"; return 1; }
}


# ---- an empty instance, as multi-tour-infra-mongo leaves it for this domain
retry 3 20 docker pull -q "$MONGO_IMAGE" >/dev/null || { echo "the MongoDB image could not be downloaded"; exit 1; }
retry 3 20 docker build -q --build-arg LIQUIBASE_BASE="$LIQUIBASE_BASE" -f deploy/liquibase.Dockerfile -t "$LIQUIBASE_IMAGE" deploy >/dev/null || { echo "the runner image did not build"; exit 1; }
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
check "I·migration_is_idempotent_when_the_control_is_lost" migration_is_idempotent_when_the_control_is_lost

# ---- the probes of the rules of the spec: an invalid document is rejected and a valid one is accepted
# A probe runs a few mongosh statements on the built database and prints one outcome: ACCEPTED, or the code
# of the error (121 the validator refused it, 11000 a unique index did). It starts from an empty collection.
PRELUDE="const id = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
  const tenant = o => Object.assign({_id: id(1), identifier: 'acme-tours', commercialName: 'Acme Tours', tenantStatus: 'ACTIVE', timeZone: 'America/Bogota', country: 'CO', createdAt: new Date()}, o);
  const insert = (collection, doc) => { try { db.getCollection(collection).insertOne(doc); return 'ACCEPTED'; } catch (e) { return String(e.code); } };
  const ins = doc => insert('tenants', doc);
  try { db.tenants.deleteMany({}); } catch (e) {}"

probe() { # name, wanted outcome, statements
  name=$1; want=$2; js=$3
  got=$(mongo "$PRELUDE $js") || got="mongosh failed"
  if [ "$got" = "$want" ]; then echo "PASS  $name"; else echo "FAIL  $name"; echo "        wanted $want, got $got"; fail=1; fi
}

probe "I·tenant_valid_document_is_accepted" "ACCEPTED" "print(ins(tenant({})))"
probe "I·tenant_identifier_is_unique" "11000" "ins(tenant({})); print(ins(tenant({_id: id(2)})))"
probe "I·failed_tenant_frees_its_identifier" "ACCEPTED,ACCEPTED" "print([ins(tenant({tenantStatus: 'FAILED', failedStep: 'CREATE_ACCOUNT'})), ins(tenant({_id: id(2), tenantStatus: 'PENDING'}))].join(','))"
probe "I·tenant_status_outside_the_list_is_rejected" "121" "print(ins(tenant({tenantStatus: 'DELETED'})))"
probe "I·tenant_identifier_with_bad_format_is_rejected" "121,121,121,121,121,121" "print(['Acme_Tours', '-acme', 'acme-', 'a--b', 'ab', 'x'.repeat(41)].map((identifier, n) => ins(tenant({_id: id(n + 1), identifier}))).join(','))"
probe "I·tenant_without_a_name_is_rejected" "121" "const doc = tenant({}); delete doc.commercialName; print(ins(doc))"
probe "I·tenant_without_a_time_zone_or_country_is_rejected" "121,121,121" "const a = tenant({_id: id(1)}); delete a.timeZone; const b = tenant({_id: id(2), identifier: 'other-one'}); delete b.country; print([ins(a), ins(b), ins(tenant({_id: id(3), identifier: 'third-one', country: 'COL'}))].join(','))"
probe "I·tenant_with_an_undeclared_field_is_rejected" "121" "print(ins(tenant({nickname: 'typo'})))"
probe "I·every_live_status_holds_the_identifier" "11000,11000,11000" "print(['PENDING', 'ACTIVE', 'INACTIVE'].map((st, n) => { ins(tenant({_id: id(n + 1), identifier: 'held-' + st.toLowerCase(), tenantStatus: st})); return ins(tenant({_id: id(n + 11), identifier: 'held-' + st.toLowerCase()})); }).join(','))"
probe "I·failed_tenants_share_an_identifier" "ACCEPTED,ACCEPTED" "print([ins(tenant({tenantStatus: 'FAILED'})), ins(tenant({_id: id(2), tenantStatus: 'FAILED'}))].join(','))"
probe "I·identifier_index_is_unique_and_partial_on_the_live_statuses" '[{"identifier":1},true,{"tenantStatus":{"$in":["PENDING","ACTIVE","INACTIVE"]}}]' "const i = db.tenants.getIndexes().find(x => x.name === 'idx_tenants_identifier'); print(JSON.stringify([i.key, i.unique, i.partialFilterExpression]))"
probe "I·tenant_text_with_a_line_break_or_only_spaces_is_rejected" "121,121,121,121,121" "print([ins(tenant({_id: id(1), identifier: 'acme-tours\\n'})), ins(tenant({_id: id(2), identifier: 'other-one', country: 'CO\\n'})), ins(tenant({_id: id(3), identifier: 'third-one', commercialName: '   '})), ins(tenant({_id: id(4) + '\\n', identifier: 'fourth-one'})), ins(tenant({_id: id(5), identifier: 'fifth-one', firstAdministratorMembershipId: 'not-a-uuid'}))].join(','))"
probe "I·tenant_identifier_limits_are_accepted" "ACCEPTED,ACCEPTED" "print([ins(tenant({_id: id(1), identifier: 'abc'})), ins(tenant({_id: id(2), identifier: 'x'.repeat(40)}))].join(','))"
probe "I·tenant_without_identifier_status_or_date_is_rejected" "121,121,121" "const a = tenant({_id: id(1)}); delete a.identifier; const b = tenant({_id: id(2), identifier: 'other-one'}); delete b.tenantStatus; const c = tenant({_id: id(3), identifier: 'third-one'}); delete c.createdAt; print([ins(a), ins(b), ins(c)].join(','))"
probe "I·tenant_with_a_bad_id_a_bad_step_or_a_wrong_type_is_rejected" "121,121,121,121" "print([ins(tenant({_id: 'ABC'})), ins(tenant({_id: id(2), identifier: 'other-one', failedStep: 'OTHER'})), ins(tenant({_id: id(3), identifier: 5})), ins(tenant({_id: id(4), identifier: 'fourth-one', createdAt: 'yesterday'}))].join(','))"
probe "I·tenant_indexes_exist_with_their_partial_filter" "_id_,idx_tenants_identifier(partial),idx_tenants_status_createdat" "print(db.tenants.getIndexes().map(i => i.name + (i.partialFilterExpression ? '(partial)' : '')).sort().join(','))"

# the single name the spec uses for the whole sequence (RN-IDA-DB-08)
[ "$fail" = 0 ] && echo "PASS  I·db_ci_builds_reruns_rolls_back_and_rebuilds"
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
