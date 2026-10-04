#!/bin/bash
# Security & Access Control Setup Script for TraceHunt ELK Stack
set -euo pipefail

ES_URL="${ES_URL:-http://127.0.0.1:9200}"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

# Helper function to generate safe JSON payloads using Python json.dumps()
# Handles special characters, quotation marks, backslashes, and spaces safely.
make_json_payload() {
  python3 -c "import json, sys; print(json.dumps(json.loads(sys.argv[1])))" "$1"
}

# Helper function to generate user account creation JSON payloads
make_user_json() {
  local password="$1"
  local roles_json="$2"
  local full_name="$3"
  python3 -c "import json, sys; print(json.dumps({'password': sys.argv[1], 'roles': json.loads(sys.argv[2]), 'full_name': sys.argv[3]}))" \
    "$password" "$roles_json" "$full_name"
}

# Helper function to perform POST/PUT requests with explicit HTTP code validation
exec_es_api() {
  local method="$1"
  local path="$2"
  local payload="$3"
  local description="$4"

  echo "-> ${description}..."
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "${ES_URL}${path}" \
    -u "elastic:${ELASTIC_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [ "$http_code" -ne 200 ] && [ "$http_code" -ne 201 ]; then
    echo "Error: ${description} failed (HTTP ${http_code})." >&2
    exit 1
  fi
  echo "   [OK] Success (HTTP ${http_code})."
}

# -----------------------------------------------------------------------------
# 1. Credentials Gathering & Admin Verification
# -----------------------------------------------------------------------------

if [ -z "${ELASTIC_PASSWORD:-}" ]; then
  read -sp "Enter Elasticsearch Admin Password (elastic): " ELASTIC_PASSWORD
  echo ""
fi

if [ -z "$ELASTIC_PASSWORD" ]; then
  echo "Error: ELASTIC_PASSWORD cannot be empty." >&2
  exit 1
fi

echo "Verifying admin access to Elasticsearch..."
http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "elastic:${ELASTIC_PASSWORD}" "$ES_URL/")
if [ "$http_code" -ne 200 ]; then
  echo "Error: Failed to authenticate as elastic user (HTTP $http_code)." >&2
  exit 1
fi
echo "[OK] Admin authentication verified."

# Gather account passwords if not set in environment
KIBANA_SYSTEM_PASSWORD="${KIBANA_SYSTEM_PASSWORD:-}"
if [ -z "$KIBANA_SYSTEM_PASSWORD" ]; then
  read -sp "Enter Password for kibana_system user: " KIBANA_SYSTEM_PASSWORD
  echo ""
fi

LOGSTASH_WRITER_USER="${LOGSTASH_WRITER_USER:-logstash_writer}"
LOGSTASH_WRITER_PASSWORD="${LOGSTASH_WRITER_PASSWORD:-}"
if [ -z "$LOGSTASH_WRITER_PASSWORD" ]; then
  read -sp "Enter Password for Logstash Writer User ($LOGSTASH_WRITER_USER): " LOGSTASH_WRITER_PASSWORD
  echo ""
fi

MCP_USER_PASSWORD="${MCP_USER_PASSWORD:-}"
if [ -z "$MCP_USER_PASSWORD" ]; then
  read -sp "Enter Password for MCP Read-Only User (mcp_user): " MCP_USER_PASSWORD
  echo ""
fi

# -----------------------------------------------------------------------------
# 2. Configure Users & Roles
# -----------------------------------------------------------------------------

# 1. Set kibana_system Password
PAYLOAD=$(python3 -c "import json, sys; print(json.dumps({'password': sys.argv[1]}))" "$KIBANA_SYSTEM_PASSWORD")
exec_es_api "POST" "/_security/user/kibana_system/_password" "$PAYLOAD" "Initializing kibana_system password"

# 2. Create Logstash Writer Role
ROLE_PAYLOAD=$(make_json_payload '{
  "cluster": ["manage_index_templates", "monitor"],
  "indices": [
    {
      "names": ["tracehunt-raw-*", "windows-security", "sysmon", "zeek", "logstash-*"],
      "privileges": ["write", "create_index", "create", "manage", "read"]
    }
  ]
}')
exec_es_api "POST" "/_security/role/logstash_writer_role" "$ROLE_PAYLOAD" "Creating logstash_writer_role"

# 3. Create Logstash Writer Account
USER_PAYLOAD=$(make_user_json "$LOGSTASH_WRITER_PASSWORD" '["logstash_writer_role"]' "Logstash Ingestion Writer Account")
exec_es_api "POST" "/_security/user/${LOGSTASH_WRITER_USER}" "$USER_PAYLOAD" "Creating ${LOGSTASH_WRITER_USER} user"

# 4. Create MCP Read-Only Role
ROLE_PAYLOAD=$(make_json_payload '{
  "cluster": ["monitor"],
  "indices": [
    {
      "names": ["tracehunt-raw-*", "windows-security", "sysmon", "zeek", "logstash-*"],
      "privileges": ["read", "view_index_metadata"]
    }
  ]
}')
exec_es_api "POST" "/_security/role/mcp_read_only" "$ROLE_PAYLOAD" "Creating mcp_read_only role"

# 5. Create MCP Read-Only User
USER_PAYLOAD=$(make_user_json "$MCP_USER_PASSWORD" '["mcp_read_only"]' "MCP Read-Only Query Account")
exec_es_api "POST" "/_security/user/mcp_user" "$USER_PAYLOAD" "Creating mcp_user"

# 6. Apply Index Template
if [ -f "index_template.json" ];  then
  TEMPLATE_PAYLOAD=$(python3 -c "import json, sys; print(json.dumps(json.load(open('index_template.json'))))")
  exec_es_api "PUT" "/_index_template/tracehunt_template" "$TEMPLATE_PAYLOAD" "Applying tracehunt_template index template"
else
  echo "Warning: index_template.json not found in current directory. Skipping template setup."
fi

# -----------------------------------------------------------------------------
# 3. Read-Back Verification
# -----------------------------------------------------------------------------

echo -e "\n--- Verifying Created Resources (Reading Back via API) ---"

verify_resource() {
  local endpoint="$1"
  local name="$2"
  
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL}${endpoint}")
  if [ "$status" -eq 200 ]; then
    echo "[VERIFIED] ${name} (${endpoint})"
  else
    echo "[ERROR] Failed to verify ${name} at ${endpoint} (HTTP ${status})" >&2
    exit 1
  fi
}

verify_resource "/_security/role/logstash_writer_role" "Logstash Writer Role"
verify_resource "/_security/user/${LOGSTASH_WRITER_USER}" "Logstash Writer User (${LOGSTASH_WRITER_USER})"
verify_resource "/_security/role/mcp_read_only" "MCP Read-Only Role"
verify_resource "/_security/user/mcp_user" "MCP Read-Only User (mcp_user)"
verify_resource "/_security/user/kibana_system" "Kibana System Account"

if [ -f "index_template.json" ]; then
  verify_resource "/_index_template/tracehunt_template" "TraceHunt Index Template"
fi

echo -e "\n[SUCCESS] Security setup completed and verified successfully!"
