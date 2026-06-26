{{- /* App DB + Postgres tuning: read git.config GITLAB_DATABASE_*; literals match chart config defaults when keys omitted. */ -}}
{{- define "cp-git.gitlabAppDbUser" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_USERNAME" | default "gitlab" -}}
{{- end -}}

{{- define "cp-git.gitlabAppDbName" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_DATABASE" | default "gitlabhq_production" -}}
{{- end -}}

{{- define "cp-git.gitlabAppDbPassword" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_PASSWORD" | default "gitlab" -}}
{{- end -}}

{{- define "cp-git.gitlabDbServicePort" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_PORT" | default "6543" | toString -}}
{{- end -}}

{{- define "cp-git.gitlabDbSharedBuffers" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_SHARED_BUFFERS" | default "256MB" -}}
{{- end -}}

{{- define "cp-git.gitlabDbMaxConnections" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_MAX_CONNECTIONS" | default "200" | toString -}}
{{- end -}}

{{- define "cp-git.gitlabDbImageTag" -}}
{{- $c := .Values.config | default dict -}}
{{- index $c "GITLAB_DATABASE_VERSION" | default "14.11" -}}
{{- end -}}

{{- define "cp-git.gitlabDbInitScript" -}}
#!/usr/bin/env bash
set -euo pipefail
LOCK_KEY="${GITLAB_DB_ADVISORY_LOCK_KEY:-8734221}"
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
export PGHOST PGPORT PGUSER PGPASSWORD
_pg_attempt=0
_pg_max=140
until pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}"; do
  _pg_attempt=$((_pg_attempt + 1))
  if [ "${_pg_attempt}" -ge "${_pg_max}" ]; then
    echo "ERROR: PostgreSQL not reachable at ${PGHOST}:${PGPORT} after $((_pg_max * 2))s"
    exit 1
  fi
  echo "gitlab-db-bootstrap: waiting for PostgreSQL at ${PGHOST}:${PGPORT} (attempt ${_pg_attempt}/${_pg_max})..."
  sleep 2
done
echo "gitlab-db-bootstrap: PostgreSQL is accepting connections."
APP_PASS_ESC=$(sql_escape "${GITLAB_APP_PASSWORD}")
psql -v ON_ERROR_STOP=1 -d postgres -c "SELECT pg_advisory_lock(${LOCK_KEY});"
unlock() {
  psql -v ON_ERROR_STOP=0 -d postgres -c "SELECT pg_advisory_unlock(${LOCK_KEY});" || true
}
trap unlock EXIT
psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
psql -v ON_ERROR_STOP=1 -d postgres -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${GITLAB_DB_USER}') THEN EXECUTE format('CREATE USER %I CREATEDB', '${GITLAB_DB_USER}'); END IF; END \$\$;"
psql -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER \"${GITLAB_DB_USER}\" WITH SUPERUSER;"
psql -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER \"${GITLAB_DB_USER}\" WITH PASSWORD '${APP_PASS_ESC}';"
DB_EXISTS=$(psql -v ON_ERROR_STOP=1 -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '${GITLAB_DB_NAME}';")
if [ "${DB_EXISTS}" != "1" ]; then
  psql -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE \"${GITLAB_DB_NAME}\" OWNER \"${GITLAB_DB_USER}\";"
fi
echo "GitLab application database and role are ready."
{{- end }}
