#!/bin/bash
# =============================================================================
# Run E2E tests for Prow CI
#
# Called by prow_run_smoke_test.sh after deployment and token setup.
# Expects TOKEN, ADMIN_OC_TOKEN, HOST, MAAS_API_BASE_URL to be exported.
#
# Environment (required):
#   TOKEN                - regular user API key / bearer token
#   HOST                 - gateway host (e.g. maas.<cluster-domain>)
#   MAAS_API_BASE_URL    - full API base URL
#   PROJECT_ROOT         - repo root
#   ARTIFACTS_DIR        - directory for test reports
#
# Environment (optional):
#   ADMIN_OC_TOKEN       - admin API key / bearer token
#   INSECURE_HTTP        - use HTTP instead of HTTPS (default: false)
#   EXTERNAL_OIDC        - enable OIDC tests (default: false)
#   OIDC_*               - OIDC configuration vars
#   DEPLOYMENT_NAMESPACE - controller namespace (default: opendatahub)
#   MAAS_SUBSCRIPTION_NAMESPACE - MaaS CRs namespace
#   GATEWAY_NAMESPACE    - gateway namespace
#   GATEWAY_NAME         - gateway name
#   MODEL_NAMESPACE      - model namespace (default: llm)
#   AITENANT_NAMESPACE   - AITenant namespace
#   ENABLE_TENANT_NAMESPACE_DISCOVERY - patch controller for discovery
#   AUTHORINO_NAMESPACE  - Authorino namespace
#   OIDC_READINESS_STRICT - fail on OIDC readiness timeout (default: true)
# =============================================================================

set -euo pipefail

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    echo "❌ ERROR: PROJECT_ROOT must be set" >&2
    exit 1
fi

# Source helpers if not already sourced
if ! type verify_gateway_oidc_authpolicy &>/dev/null 2>&1; then
    source "$PROJECT_ROOT/scripts/deployment-helpers.sh" 2>/dev/null || true
fi

INSECURE_HTTP="${INSECURE_HTTP:-false}"
EXTERNAL_OIDC="${EXTERNAL_OIDC:-false}"
OIDC_READINESS_STRICT="${OIDC_READINESS_STRICT:-true}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-llm}"
DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-opendatahub}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
AITENANT_NAMESPACE="${AITENANT_NAMESPACE:-ai-tenants}"
ENABLE_TENANT_NAMESPACE_DISCOVERY="${ENABLE_TENANT_NAMESPACE_DISCOVERY:-true}"
AUTHORINO_NAMESPACE="${AUTHORINO_NAMESPACE:-kuadrant-system}"

echo "-- E2E Tests (API Keys + Subscription + Models Endpoint) --"

export GATEWAY_HOST="${HOST}"
export DEPLOYMENT_NAMESPACE
export MAAS_SUBSCRIPTION_NAMESPACE="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
export GATEWAY_NAMESPACE
export GATEWAY_NAME
export AITENANT_NAMESPACE
export ENABLE_TENANT_NAMESPACE_DISCOVERY

# Patch controller for tenant namespace discovery if needed
enable_tenant_namespace_discovery_for_e2e() {
    if [[ "${ENABLE_TENANT_NAMESPACE_DISCOVERY}" != "true" ]]; then
        echo "Tenant namespace discovery disabled"
        return 0
    fi
    echo "Enabling tenant namespace discovery for e2e tests..."
    local controller_deploy="maas-controller"
    local current_args
    current_args=$(oc get deployment "$controller_deploy" -n "$DEPLOYMENT_NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "")

    if [[ "$current_args" == *"--enable-tenant-namespace-discovery=true"* ]]; then
        echo "✅ Tenant namespace discovery already enabled"
        return 0
    fi

    oc patch deployment "$controller_deploy" -n "$DEPLOYMENT_NAMESPACE" --type=json \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--enable-tenant-namespace-discovery=true"}]'
    oc rollout status deployment/"$controller_deploy" -n "$DEPLOYMENT_NAMESPACE" --timeout=120s
    echo "✅ Tenant namespace discovery enabled and controller restarted"
}

enable_tenant_namespace_discovery_for_e2e || exit 1

export E2E_SKIP_TLS_VERIFY=true
export MODEL_NAME="facebook-opt-125m-simulated"
export E2E_MODEL_NAMESPACE="$MODEL_NAMESPACE"

local_test_dir="$PROJECT_ROOT/test/e2e"
mkdir -p "$ARTIFACTS_DIR"

# Python venv setup
if [[ ! -d "$local_test_dir/.venv" ]]; then
    echo "Creating Python venv for e2e tests..."
    python3 -m venv "$local_test_dir/.venv" --upgrade-deps
fi
source "$local_test_dir/.venv/bin/activate"
python -m pip install --upgrade pip --quiet
python -m pip install -r "$local_test_dir/requirements.txt" --quiet

user="$(oc whoami 2>/dev/null || echo 'unknown')"
html="$ARTIFACTS_DIR/e2e-${user}.html"
xml="$ARTIFACTS_DIR/e2e-${user}.xml"

echo "Running e2e tests with:"
echo "  - TOKEN: $(echo "${TOKEN:-not set}" | cut -c1-20)..."
echo "  - ADMIN_OC_TOKEN: $(echo "${ADMIN_OC_TOKEN:-not set}" | cut -c1-20)..."
echo "  - GATEWAY_HOST: ${GATEWAY_HOST}"

# Wait for gateway reachability
scheme="https"
[[ "$INSECURE_HTTP" == "true" ]] && scheme="http"
gw_url="${scheme}://${GATEWAY_HOST}/maas-api/health"
gw_timeout=120
gw_deadline=$((SECONDS + gw_timeout))
echo "Waiting for gateway to be reachable: ${gw_url} (timeout: ${gw_timeout}s)..."
while [[ $SECONDS -lt $gw_deadline ]]; do
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "$gw_url" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^2 ]]; then
        echo "✅ Gateway is reachable (HTTP $http_code)"
        break
    fi
    sleep 1
done
if [[ $SECONDS -ge $gw_deadline ]]; then
    echo "⚠️  WARNING: Gateway not reachable after ${gw_timeout}s, proceeding anyway"
fi

# Wait for authenticated gateway access
api_base="${scheme}://${GATEWAY_HOST}/maas-api"
auth_timeout=180
auth_deadline=$((SECONDS + auth_timeout))
echo "Waiting for authenticated gateway access (timeout: ${auth_timeout}s)..."
while [[ $SECONDS -lt $auth_deadline ]]; do
    auth_code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 \
        -H "Authorization: Bearer ${TOKEN}" \
        "${api_base}/v1/subscriptions" 2>/dev/null || echo "000")
    if [[ "$auth_code" == "200" ]]; then
        echo "✅ Authenticated gateway access working (HTTP $auth_code)"
        break
    fi
    echo "  Auth check returned HTTP $auth_code, retrying..."
    sleep 5
done
if [[ $SECONDS -ge $auth_deadline ]]; then
    echo "❌ ERROR: Authenticated gateway access not working after ${auth_timeout}s"
    echo "   Check AuthPolicy: kubectl get authpolicy -A -o wide"
    echo "   Check Authorino: kubectl logs -n ${AUTHORINO_NAMESPACE} -l app=authorino --tail=50"
    exit 1
fi

# OIDC readiness check (when enabled)
if [[ "${EXTERNAL_OIDC}" == "true" ]] && [[ -n "${OIDC_TOKEN_URL:-}" ]]; then
    if [[ -n "${OIDC_ISSUER_URL:-}" ]]; then
        echo "Checking gateway AuthPolicy OIDC issuer matches OIDC_ISSUER_URL..."
        if ! verify_gateway_oidc_authpolicy "${GATEWAY_NAMESPACE}"; then
            echo "❌ ERROR: OIDC issuer mismatch"
            exit 1
        fi
    fi
    oidc_timeout=180
    oidc_deadline=$((SECONDS + oidc_timeout))
    echo "Verifying OIDC token authentication works (timeout: ${oidc_timeout}s)..."
    oidc_token=$(curl -sk -m 10 \
        -d "grant_type=password&client_id=${OIDC_CLIENT_ID}&username=${OIDC_USERNAME}&password=${OIDC_PASSWORD}&scope=openid" \
        "${OIDC_TOKEN_URL}" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
    if [[ -n "$oidc_token" ]]; then
        while [[ $SECONDS -lt $oidc_deadline ]]; do
            oidc_code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 \
                -H "Authorization: Bearer ${oidc_token}" \
                -H "Content-Type: application/json" \
                -d "{\"name\": \"e2e-oidc-readiness-$(date +%s)\"}" \
                "${api_base}/v1/api-keys" 2>/dev/null || echo "000")
            if [[ "$oidc_code" =~ ^(200|201)$ ]]; then
                echo "✅ OIDC token authentication working (HTTP $oidc_code)"
                break
            fi
            echo "  OIDC auth check returned HTTP $oidc_code, retrying..."
            sleep 5
        done
        if [[ $SECONDS -ge $oidc_deadline ]]; then
            echo "⚠️  WARNING: OIDC gateway readiness failed after ${oidc_timeout}s"
            if [[ "${OIDC_READINESS_STRICT}" == "true" ]]; then
                echo "❌ ERROR: OIDC_READINESS_STRICT=true — exiting."
                exit 1
            fi
        fi
    else
        echo "❌ ERROR: Could not obtain OIDC token from ${OIDC_TOKEN_URL}"
        exit 1
    fi
fi

# Run pytest
export E2E_RECONCILE_WAIT="${E2E_RECONCILE_WAIT:-4}"
if ! PYTHONPATH="$local_test_dir:${PYTHONPATH:-}" pytest \
    -v --maxfail=5 --disable-warnings \
    --junitxml="$xml" \
    --html="$html" --self-contained-html \
    --capture=tee-sys --show-capture=all --log-level=INFO \
    "$local_test_dir/tests/test_api_keys.py" \
    "$local_test_dir/tests/test_namespace_scoping.py" \
    "$local_test_dir/tests/test_negative_security.py" \
    "$local_test_dir/tests/test_subscription.py" \
    "$local_test_dir/tests/test_models_endpoint.py" \
    "$local_test_dir/tests/test_external_models.py" \
    "$local_test_dir/tests/test_tenant.py" \
    "$local_test_dir/tests/test_aitenant_lifecycle.py" \
    "$local_test_dir/tests/test_tenant_namespace_discovery.py" \
    "$local_test_dir/tests/test_gateway_scoped_authpolicy.py" \
    "$local_test_dir/tests/test_multi_tenant_integration.py" \
    "$local_test_dir/tests/test_tenant_model_inference.py" \
    "$local_test_dir/tests/test_multi_tenant_maas_api.py" \
    "$local_test_dir/tests/test_tenant_auth_isolation.py" \
    "$local_test_dir/tests/test_tenant_subscription_isolation.py" \
    "$local_test_dir/tests/test_tenant_rate_limit_isolation.py" \
    "$local_test_dir/tests/test_config_tenant.py" \
    "$local_test_dir/tests/test_tenant_discovery.py" \
    "$local_test_dir/tests/test_tenant_discovery_isolation.py" \
    "$local_test_dir/tests/test_per_tenant_ipp_isolation.py" \
    "$local_test_dir/tests/test_external_oidc.py" ; then
    echo "❌ ERROR: E2E tests failed"
    exit 1
fi

echo "✅ E2E tests completed"
echo " - JUnit XML : ${xml}"
echo " - HTML      : ${html}"
