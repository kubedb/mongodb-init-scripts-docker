#!/bin/bash

# Copyright The KubeDB Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ref: https://github.com/kubernetes/charts/blob/master/stable/mongodb-replicaset/init/on-start.sh

source /init-scripts/common.sh
replica_set="$REPLICA_SET"
script_name=${0##*/}

sleep $DEFAULT_WAIT_SECS

if [[ "$AUTH" == "true" ]]; then
    admin_user="$MONGO_INITDB_ROOT_USERNAME"
    admin_password="$MONGO_INITDB_ROOT_PASSWORD"
    admin_creds=(-u "$admin_user" -p "$admin_password" --authenticationDatabase admin)
    auth_args=(--clusterAuthMode ${CLUSTER_AUTH_MODE} --sslMode ${SSL_MODE} --auth --keyFile=/data/configdb/key.txt)
fi

my_hostname=$(hostname)
log "Bootstrapping MongoDB replica set member: $my_hostname"

log "Reading standard input..."
while read -ra line; do
    if [[ "${line}" == *"${my_hostname}"* ]]; then
        service_name="$line"
        continue
    fi
    peers=("${peers[@]}" "$line")
done

# set the cert files as ssl_args
if [[ ${SSL_MODE} != "disabled" ]]; then
    ca_crt=/var/run/mongodb/tls/ca.crt
    pem=/var/run/mongodb/tls/mongo.pem
    client_pem=/var/run/mongodb/tls/client.pem
    if [[ ! -f "$ca_crt" ]] || [[ ! -f "$pem" ]] || [[ ! -f "$client_pem" ]]; then
        log "ENABLE_SSL is set to true, but $ca_crt or $pem or $client_pem file does not exist"
        exit 1
    fi

    ssl_args=(--tls --tlsCAFile "$ca_crt" --tlsCertificateKeyFile "$pem")
    auth_args=(--clusterAuthMode ${CLUSTER_AUTH_MODE} --sslMode ${SSL_MODE} --tlsCAFile "$ca_crt" --tlsCertificateKeyFile "$pem" --keyFile=/data/configdb/key.txt)
fi

log "Peers: ${peers[*]}"

log "Waiting for MongoDB to be ready..."
until mongo --host localhost "${ssl_args[@]}" --eval "db.adminCommand('ping')"; do
    log "Retrying to ping..."
    sleep 2
done

log "Initialized."

# check if the replica is already added in replicaset
if [[ $(mongo admin --host localhost "${admin_creds[@]}" "${ssl_args[@]}" --quiet --eval "rs.status().myState") == '2' ]]; then
    log "($service_name) already added in replicaset"
    log "Good bye."
    exit 0
else
    # try to find a master and add yourself to its replica set.
    for peer in "${peers[@]}"; do
        if mongo admin --host "$peer" "${admin_creds[@]}" "${ssl_args[@]}" --eval "rs.isMaster()" | grep '"ismaster" : true'; then
            log "Found master: $peer"

            log "Adding myself ($service_name) to replica set..."
            retry mongo admin --host "$peer" "${admin_creds[@]}" "${ssl_args[@]}" --quiet --eval "JSON.stringify(rs.add('$service_name'))"

            sleep $DEFAULT_WAIT_SECS

            log 'Waiting for replica to reach SECONDARY state...'
            until printf '.' && [[ $(mongo admin --host localhost "${admin_creds[@]}" "${ssl_args[@]}" --quiet --eval "rs.status().myState") == '2' ]]; do
                sleep 1
            done

            log '✓ Replica reached SECONDARY state.'

            log "Good bye."
            exit 0
        fi
    done
fi

# else initiate a replica set with yourself.
if mongo --host localhost "${ssl_args[@]}" --eval "rs.status()" | grep "no replset config has been received"; then
    log "Initiating a new replica set with myself ($service_name)..."
    retry mongo --host localhost "${ssl_args[@]}" --quiet --eval "JSON.stringify(rs.initiate({'_id': '$replica_set', 'writeConcernMajorityJournalDefault': false, 'members': [{'_id': 0, 'host': '$service_name'}]}))"

    sleep $DEFAULT_WAIT_SECS

    log 'Waiting for replica to reach PRIMARY state...'
    until printf '.' && [[ $(mongo --host localhost "${ssl_args[@]}" --quiet --eval "rs.status().myState") == '1' ]]; do
        sleep 1
    done

    log '✓ Replica reached PRIMARY state.'

    if [[ "$AUTH" == "true" ]]; then
        log "Creating admin user..."
        mongo admin --host localhost "${ssl_args[@]}" --quiet --eval "db.createUser({user: '$admin_user', pwd: '$admin_password', roles: [{role: 'root', db: 'admin'}]})"
    fi

    # Initialize Part for KubeDB.
    # ref: https://github.com/docker-library/mongo/blob/a499e81e743b05a5237e2fd700c0284b17d3d416/3.4/docker-entrypoint.sh#L302
    # Start
    export MONGO_INITDB_DATABASE="${MONGO_INITDB_DATABASE:-test}"

    echo
    ls -la /docker-entrypoint-initdb.d
    for f in /docker-entrypoint-initdb.d/*; do
        case "$f" in
            *.sh)
                echo "$0: running $f"
                . "$f"
                ;;
            *.js)
                echo "$0: running $f 1"
                mongo --host localhost "$MONGO_INITDB_DATABASE" "${admin_creds[@]}" "${ssl_args[@]}" "$f"
                ;;
            *) echo "$0: ignoring $f" ;;
        esac
        echo
    done
    # END

    log "Done."
fi

if [[ ${SSL_MODE} != "disabled" ]] && [[ -f "$client_pem" ]]; then
    user=$(openssl x509 -in "$client_pem" -inform PEM -subject -nameopt RFC2253 -noout)
    # remove prefix 'subject= ' or 'subject='
    user=$(echo ${user#"subject="})
    #xref: https://docs.mongodb.com/manual/tutorial/configure-x509-client-authentication/#procedures
    log "Creating root user $user for SSL..."
    mongo admin --host localhost "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.getSiblingDB(\"\$external\").runCommand({createUser: \"$user\",roles:[{role: 'root', db: 'admin'}],})"
fi

log "Good bye."
