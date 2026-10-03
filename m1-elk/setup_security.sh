#!/bin/bash
# Security & Access Control Setup Script for TraceHunt ELK

ES_URL="http://localhost:9200"

echo "1. Creating MCP Read-Only Role..."
curl -s -X POST "$ES_URL/_security/role/mcp_read_only" \
  -H "Content-Type: application/json" \
  -d '{
    "cluster": ["monitor"],
    "indices": [
      {
        "names": ["tracehunt-*", "logstash-*"],
        "privileges": ["read", "view_index_metadata"]
      }
    ]
  }'

echo -e "\n2. Creating MCP Server User..."
curl -s -X POST "$ES_URL/_security/user/mcp_user" \
  -H "Content-Type: application/json" \
  -d '{
    "password": "mcp_secure_password_123",
    "roles": ["mcp_read_only"],
    "full_name": "MCP Server Read-Only Account",
    "email": "mcp@tracehunt.local"
  }'

echo -e "\n3. Applying Index Template..."
curl -s -X PUT "$ES_URL/_index_template/tracehunt_template" \
  -H "Content-Type: application/json" \
  -d @index_template.json

echo -e "\nSecurity and Index Template setup complete!"
