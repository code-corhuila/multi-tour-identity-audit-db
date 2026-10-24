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
    const app = db.getUser('identity_audit_app');
    print('changesets=' + rows.map(r => r.id + '@' + r.md5sum).join(',') + ' roles=' + db.getRoles().roles.map(r => r.role).sort().join(',') + ' app=' + (app ? app.roles.map(r => r.role).sort().join(',') : 'MISSING') + ' collections=' + data.map(n => n + '[' + db.getCollection(n).getIndexes().map(i => i.name).sort().join('|') + ']' + JSON.stringify(db.getCollectionInfos({name: n})[0].options)).join(','))"
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
  case $now in "changesets= roles= app=readWrite collections=") ;; *) echo "the rollback left something: $now"; return 1 ;; esac
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

# HU-IDA-003 (RN-IDA-DB-13, -14, -15): undo only the changeset that adds the visual identity (and what ran after
# it), so the validator of the first spec is back, and leave a tenant written under it.
rollback_restores_the_previous_validator() {
  n=$(mongo "const rows = db.getCollection('databasechangelog_identity_audit').find({}, {id: 1}).sort({orderExecuted: 1}).toArray(); const at = rows.findIndex(r => r.id === 'ddl-collections-tenants-002'); print(at < 0 ? 'MISSING' : rows.length - at)") || { echo "could not read the changesets"; return 1; }
  [ "$n" != "MISSING" ] || { echo "changeset ddl-collections-tenants-002 was never applied"; return 1; }
  out=$(lb rollback-count "$n" 2>&1) || { printf '%s\n' "$out" | tail -n 8; return 1; }
  got=$(mongo "const t = o => Object.assign({_id: '00000000-0000-4000-8000-000000000001', identifier: 'acme-tours', commercialName: 'Acme Tours', tenantStatus: 'ACTIVE', timeZone: 'America/Bogota', country: 'CO', createdAt: new Date()}, o);
    db.tenants.deleteMany({});
    let refused = 'ACCEPTED'; try { db.tenants.insertOne(t({visualIdentity: {primaryColor: '#112233', secondaryColor: '#445566'}})); } catch (e) { refused = String(e.code); }
    db.tenants.insertOne(t({_id: '00000000-0000-4000-8000-000000000077', identifier: 'legacy-tours'}));
    print(refused)") || { echo "could not probe the restored validator"; return 1; }
  [ "$got" = "121" ] || { echo "the validator of the first spec was not restored, got $got"; return 1; }
}

# the legacy tenant, written before the change, is valid under the new validator and can take the identity
legacy_tenant_can_be_updated_after_the_change() {
  got=$(mongo "const r = db.tenants.updateOne({_id: '00000000-0000-4000-8000-000000000077'}, {\$set: {commercialName: 'Legacy Tours S.A.', visualIdentity: {primaryColor: '#112233', secondaryColor: '#445566'}}}); print(r.matchedCount + ',' + r.modifiedCount)") || { echo "the update was refused"; return 1; }
  [ "$got" = "1,1" ] || { echo "wanted 1,1 got $got"; return 1; }
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

# What the infrastructure leaves for the domain: the user of the connection, with the role of the instance. The
# password is made here, used by nobody and thrown away with the container.
mongo "db.createUser({user: 'identity_audit_app', pwd: crypto.randomUUID(), roles: [{role: 'readWrite', db: 'identity_audit'}]})" >/dev/null || { echo "could not create the instance user"; exit 1; }

check "I·db_ci_builds_from_empty" lb update
check "I·db_ci_second_update_changes_nothing" second_update_changes_nothing
check "I·db_ci_rolls_back_to_empty" rolled_back_to_empty
check "I·db_ci_rebuilds_after_the_rollback" lb update
check "I·migration_is_idempotent_when_the_control_is_lost" migration_is_idempotent_when_the_control_is_lost
check "I·rollback_restores_the_previous_validator" rollback_restores_the_previous_validator
check "I·db_ci_reapplies_over_a_database_with_a_tenant" lb update
check "I·tenant_created_before_the_change_can_be_updated" legacy_tenant_can_be_updated_after_the_change
check "I·db_ci_second_update_changes_nothing_with_data" second_update_changes_nothing

# ---- the probes of the rules of the spec: an invalid document is rejected and a valid one is accepted
# A probe runs a few mongosh statements on the built database and prints one outcome: ACCEPTED, or the code
# of the error (121 the validator refused it, 11000 a unique index did). It starts from an empty collection.
PRELUDE="const id = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
  const tenant = o => Object.assign({_id: id(1), identifier: 'acme-tours', commercialName: 'Acme Tours', tenantStatus: 'ACTIVE', timeZone: 'America/Bogota', country: 'CO', createdAt: new Date()}, o);
  const insert = (collection, doc) => { try { db.getCollection(collection).insertOne(doc); return 'ACCEPTED'; } catch (e) { return String(e.code); } };
  const ins = doc => insert('tenants', doc);
  const event = o => Object.assign({_id: id(1), eventType: 'TenantCreated', eventVersion: NumberInt(1), aggregateId: id(1), payload: {tenantId: id(1)}, correlationId: 'corr-1', occurredAt: new Date(), status: 'PENDING', attempts: NumberInt(0), nextAttemptAt: new Date()}, o);
  const evt = doc => insert('outbox_events', doc);
  const repeatKey = o => Object.assign({key: 'onboard-tenant:1:1', operation: 'registerPendingTenant', resourceId: id(1), createdAt: new Date()}, o);
  const keys = doc => insert('idempotency_keys', doc);
  const processed = o => Object.assign({_id: id(1), processedAt: new Date()}, o);
  const pe = doc => insert('processed_events', doc);
  const cutoff = o => Object.assign({_id: id(1), tenantId: id(2), revokedFrom: new Date(), updatedAt: new Date()}, o);
  const cut = doc => insert('account_session_cutoffs', doc);
  for (const c of ['tenants', 'outbox_events', 'idempotency_keys', 'processed_events', 'account_session_cutoffs']) { try { db.getCollection(c).deleteMany({}); } catch (e) {} }"

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
probe "I·tenant_indexes_exist_with_their_partial_filter" "_id_,idx_tenants_createdat_id,idx_tenants_identifier(partial),idx_tenants_status_createdat,idx_tenants_status_createdat_id" "print(db.tenants.getIndexes().map(i => i.name + (i.partialFilterExpression ? '(partial)' : '')).sort().join(','))"

# HU-IDA-003: the visual identity is two colors, #RRGGBB, all or nothing, and optional
VI="const vi = o => Object.assign({primaryColor: '#1A2B3C', secondaryColor: '#aabbcc'}, o); const withVi = (n, v) => ins(tenant({_id: id(n), identifier: 'tenant-' + n, visualIdentity: v}));"
probe "I·visual_identity_with_two_hex_colors_is_accepted" "ACCEPTED,ACCEPTED" "$VI print([withVi(1, vi({})), withVi(2, null)].join(','))"
probe "I·visual_identity_with_a_bad_color_is_rejected" "121,121,121,121,121,121,121" "$VI print([vi({primaryColor: '1A2B3C'}), vi({primaryColor: '#1A2B3'}), vi({secondaryColor: '#GGGGGG'}), vi({secondaryColor: '#1A2B3C\\n'}), vi({primaryColor: '#1A2B3C4'}), vi({primaryColor: 'red'}), vi({secondaryColor: 7})].map((v, n) => withVi(n + 1, v)).join(','))"
probe "I·visual_identity_with_one_color_is_rejected" "121,121" "$VI print([{primaryColor: '#1A2B3C'}, {secondaryColor: '#1A2B3C'}].map((v, n) => withVi(n + 1, v)).join(','))"
probe "I·visual_identity_with_an_undeclared_field_is_rejected" "121,121" "$VI print([vi({logo: 'x.png'}), vi({font: 'Comic Sans'})].map((v, n) => withVi(n + 1, v)).join(','))"
probe "I·tenant_without_a_visual_identity_is_accepted" "ACCEPTED" "print(ins(tenant({})))"
probe "I·outbox_valid_event_is_accepted" "ACCEPTED" "print(evt(event({})))"
probe "I·outbox_event_with_a_bad_state_or_number_is_rejected" "121,121,121,121" "print([evt(event({_id: id(1), status: 'DONE'})), evt(event({_id: id(2), attempts: NumberInt(-1)})), evt(event({_id: id(3), eventVersion: NumberInt(0)})), evt(event({_id: id(4), eventType: ''}))].join(','))"
probe "I·outbox_event_without_its_required_fields_is_rejected" "121,121,121,121,121" "print(['eventType', 'aggregateId', 'payload', 'correlationId', 'occurredAt'].map((field, n) => { const doc = event({_id: id(n + 1)}); delete doc[field]; return evt(doc); }).join(','))"
probe "I·outbox_event_with_an_undeclared_field_or_a_wrong_type_is_rejected" "121,121,121" "print([evt(event({_id: id(1), extra: true})), evt(event({_id: id(2), payload: 'text'})), evt(event({_id: id(3), occurredAt: 'today'}))].join(','))"
probe "I·outbox_indexes_serve_the_pending_listing_and_the_purge" '[{"status":1,"nextAttemptAt":1,"occurredAt":1},{"publishedAt":1}]' "const keyOf = name => db.outbox_events.getIndexes().find(i => i.name === name).key; print(JSON.stringify([keyOf('idx_outbox_events_pending'), keyOf('idx_outbox_events_publishedat')]))"
probe "I·list_plans_use_an_index_with_no_sort_stage" "idx_tenants_createdat_id,idx_tenants_status_createdat_id,idx_outbox_events_due" "const plan = q => { const stages = []; let index = ''; const walk = p => { if (!p) return; stages.push(p.stage); if (p.indexName) index = p.indexName; walk(p.inputStage); (p.inputStages || []).forEach(walk); }; walk(q.explain('queryPlanner').queryPlanner.winningPlan); return (stages.includes('SORT') ? 'SORT+' : '') + index; }; for (let n = 1; n <= 12; n++) { ins(tenant({_id: id(n), identifier: 'tenant-' + n, tenantStatus: ['ACTIVE', 'INACTIVE', 'PENDING'][n % 3], createdAt: new Date(Date.now() - n * 1000)})); evt(event({_id: id(n), aggregateId: id(n), occurredAt: new Date(Date.now() - n * 1000), nextAttemptAt: new Date(Date.now() - n * 1000)})); } print([plan(db.tenants.find({}).sort({createdAt: -1, _id: -1})), plan(db.tenants.find({tenantStatus: 'ACTIVE'}).sort({createdAt: -1, _id: -1})), plan(db.outbox_events.find({status: 'PENDING', nextAttemptAt: {\$lte: new Date()}}).sort({nextAttemptAt: 1, occurredAt: 1, _id: 1}))].join(','))"
probe "I·repeat_key_is_stored_once_per_operation" "ACCEPTED,11000" "print([keys(repeatKey({})), keys(repeatKey({resourceId: id(2)}))].join(','))"
probe "I·same_key_in_another_operation_is_accepted" "ACCEPTED,ACCEPTED" "print([keys(repeatKey({})), keys(repeatKey({operation: 'otherOperation'}))].join(','))"
probe "I·repeat_key_with_a_bad_shape_is_rejected" "121,121,121,121,121" "const noResource = repeatKey({}); delete noResource.resourceId; print([keys(repeatKey({key: 'short'})), keys(repeatKey({key: 'k'.repeat(129)})), keys(repeatKey({key: 'has a space'})), keys(repeatKey({extra: 1})), keys(noResource)].join(','))"
probe "I·repeat_key_index_is_unique_on_operation_and_key" '[{"operation":1,"key":1},true]' "const i = db.idempotency_keys.getIndexes().find(x => x.name === 'idx_idempotency_keys_operation_key'); print(JSON.stringify([i.key, i.unique]))"

probe "I·outbox_event_numbers_accept_int_and_long_and_refuse_a_decimal" "ACCEPTED,ACCEPTED,121,121" "print([evt(event({_id: id(1), eventVersion: NumberLong('1')})), evt(event({_id: id(2), attempts: NumberLong('3')})), evt(event({_id: id(3), eventVersion: 1.5})), evt(event({_id: id(4), attempts: 0.5}))].join(','))"
probe "I·outbox_event_status_and_dates_have_the_exact_form" "121,121" "print([evt(event({_id: id(1), status: 'pending'})), evt(event({_id: id(2), nextAttemptAt: 'soon'}))].join(','))"
probe "I·outbox_event_without_any_of_its_ten_required_fields_is_rejected" "121,121,121,121,121" "print(['_id', 'eventVersion', 'status', 'attempts', 'nextAttemptAt'].map((field, n) => { const doc = event({_id: id(n + 1)}); delete doc[field]; if (field === '_id') doc._id = undefined; return evt(doc); }).join(','))"
probe "I·outbox_event_text_with_a_line_break_a_space_or_too_long_is_rejected" "121,121,121,121,121,121,121,121" "print([evt(event({_id: id(1), aggregateId: id(1) + '\\n'})), evt(event({_id: id(2), correlationId: 'corr 2'})), evt(event({_id: id(3), eventType: 'Tenant Created'})), evt(event({_id: id(4), correlationId: 'c'.repeat(129)})), evt(event({_id: id(5), reason: 'r'.repeat(501)})), evt(event({_id: id(6), lastError: 'e'.repeat(1001)})), evt(event({_id: id(7), tenantId: 'not-a-uuid'})), evt(event({_id: id(8), actorId: ' '}))].join(','))"
probe "I·repeat_key_text_with_a_line_break_or_a_bad_resource_is_rejected" "121,121,121,121" "print([keys(repeatKey({key: 'onboard-tenant:1:1\\n'})), keys(repeatKey({key: 'has a space'})), keys(repeatKey({resourceId: 'not-a-uuid'})), keys(repeatKey({operation: 'two words'}))].join(','))"
probe "I·repeat_key_index_serves_the_purge_by_age" '{"createdAt":1}' "print(JSON.stringify(db.idempotency_keys.getIndexes().find(i => i.name === 'idx_idempotency_keys_createdat').key))"

# HU-WRK-007 AC2: what identity-audit keeps to cut the sessions of a revoked account (ADR-004 D4 and D5)
probe "I·processed_event_and_cutoff_valid_documents_are_accepted" "ACCEPTED,ACCEPTED,ACCEPTED" "print([pe(processed({})), cut(cutoff({})), cut(cutoff({_id: id(3), tenantId: null}))].join(','))"
probe "I·validator_refuses_a_processed_event_or_a_cutoff_that_is_malformed" "121,121,121,121,121,121,121,121" "const noDate = processed({_id: id(3)}); delete noDate.processedAt; const noFrom = cutoff({_id: id(6)}); delete noFrom.revokedFrom; print([pe(processed({_id: 'ABC'})), pe(processed({_id: id(2), extra: true})), pe(noDate), pe(processed({_id: id(4), processedAt: 'today'})), cut(cutoff({_id: 'ABC'})), cut(cutoff({_id: id(5), tenantId: 'not-a-uuid'})), cut(noFrom), cut(cutoff({_id: id(7), nickname: 'typo'}))].join(','))"
probe "I·a_second_cutoff_or_processed_row_for_the_same_id_is_refused" "ACCEPTED,11000,ACCEPTED,11000" "print([pe(processed({})), pe(processed({})), cut(cutoff({})), cut(cutoff({}))].join(','))"
probe "I·cutoff_and_processed_event_edges_are_rejected" "121,121,121,121,121,121" "const noUpdated = cutoff({_id: id(4)}); delete noUpdated.updatedAt; print([pe(processed({_id: id(1) + '\n'})), cut(cutoff({_id: id(2), tenantId: id(2) + '\n'})), cut(cutoff({_id: 'ABCDEF01-0000-4000-8000-000000000003'})), cut(noUpdated), cut(cutoff({_id: id(5), revokedFrom: 'now'})), cut(cutoff({_id: id(6), tenantId: 7}))].join(','))"
probe "I·processed_event_index_serves_the_purge_by_age" '{"processedAt":1}' "print(JSON.stringify(db.processed_events.getIndexes().find(i => i.name === 'idx_processed_events_processedat').key))"

probe "I·roles_reader_and_writer_exist_and_are_the_only_ones" "identity_audit_reader,identity_audit_writer" "print(db.getRoles().roles.map(r => r.role).sort().join(','))"
probe "I·reader_role_can_only_read_the_collections_of_the_domain" '[{"resource":{"db":"identity_audit","collection":""},"actions":["find"]}]' "print(JSON.stringify(db.getRole('identity_audit_reader', {showPrivileges: true}).privileges))"
probe "I·writer_role_reads_and_writes_the_collections_of_the_domain_and_changes_no_structure" '[{"resource":{"db":"identity_audit","collection":""},"actions":["find","insert","remove","update"]}]' "print(JSON.stringify(db.getRole('identity_audit_writer', {showPrivileges: true}).privileges.map(p => ({resource: p.resource, actions: p.actions.slice().sort()}))))"
probe "I·roles_hold_no_other_role_and_no_password" '[[],[]]' "print(JSON.stringify(['identity_audit_reader', 'identity_audit_writer'].map(r => db.getRole(r).roles)))"
probe "I·app_user_holds_the_reader_and_the_writer_roles" "identity_audit_reader,identity_audit_writer,readWrite" "print(db.getUser('identity_audit_app').roles.map(r => r.role).sort().join(','))"

# the single name the spec uses for the whole sequence (RN-IDA-DB-08)
[ "$fail" = 0 ] && echo "PASS  I·db_ci_builds_reruns_rolls_back_and_rebuilds"
[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
