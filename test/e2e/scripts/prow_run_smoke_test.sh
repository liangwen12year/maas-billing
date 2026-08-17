#!/bin/bash

# =============================================================================
# MaaS Platform E2E Orchestrator (Prow CI)
# =============================================================================
#
# Thin orchestrator: prereqs → deploy → models → tokens → validate → tests.
# All implementation logic lives in the scripts called below.
#
# USAGE:
#   ./test/e2e/scripts/prow_run_smoke_test.sh
#
# ENVIRONMENT VARIABLES:
#   SKIP_DEPLOYMENT     - Skip platform and model deployment (default: false)
#   SKIP_VALIDATION     - Skip deployment validation (default: false)
#   SKIP_AUTH_CHECK     - Skip Authorino readiness check (default: true)
#   INSECURE_HTTP       - Use HTTP instead of HTTPS (default: false)
#   EXTERNAL_OIDC       - Enable external OIDC (default: false)
#   MAAS_API_IMAGE      - Custom MaaS API image (optional)
#   MAAS_CONTROLLER_IMAGE - Custom controller image (optional)
#   AI_GATEWAY_OPERATOR_IMAGE - Custom ai-gateway-operator image (optional)
#   OPERATOR_CATALOG    - ODH catalog image (optional)
#   OPERATOR_IMAGE      - Custom ODH operator image (optional)
#   DEPLOY_MODE         - kustomize (default) or operator
#   POLICY_ENGINE       - rhcl (default) or kuadrant
#   RHCL_NAMESPACE      - RHCL namespace (default: kuadrant-system)
#   RHCL_STARTING_CSV   - Optional RHCL CSV pin
#   DEPLOYMENT_NAMESPACE - Controller namespace (default: opendatahub)
#   MAAS_SUBSCRIPTION_NAMESPACE - MaaS CRs namespace (default: models-as-a-service)
#   MODEL_NAMESPACE     - Models namespace (default: llm)
#   GATEWAY_NAMESPACE   - Gateway namespace (default: openshift-ingress)
#   GATEWAY_NAME        - Gateway name (default: maas-default-gateway)
#   INGRESS_MODE        - clusterip (default) or route
#   ENABLE_TENANT_NAMESPACE_DISCOVERY - Enable discovery (default: true)
#   AITENANT_NAMESPACE  - AITenant namespace (default: ai-tenants)
#   OIDC_ISSUER_URL, OIDC_TOKEN_URL, OIDC_CLIENT_ID, OIDC_USERNAME, OIDC_PASSWORD
#   OIDC_READINESS_STRICT - Fail on OIDC timeout (default: true)
#
# TIMEOUT CONFIGURATION (seconds, from deployment-helpers.sh):
#   CUSTOM_RESOURCE_TIMEOUT, LLMIS_TIMEOUT, MAASMODELREF_TIMEOUT,
#   AUTHPOLICY_TIMEOUT, AUTHORINO_TIMEOUT, ROLLOUT_TIMEOUT,
#   GATEWAY_PROGRAMMED_TIMEOUT
# =============================================================================

set -euo pipefail

# --- Project root and helpers ---

_find_project_root_bootstrap() {
  local dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  while [[ "$dir" != "/" && ! -e "$dir/.git" ]]; do
    dir="$(dirname "$dir")"
  done
  [[ -e "$dir/.git" ]] && printf '%s\n' "$dir" || return 1
}

PROJECT_ROOT="$(_find_project_root_bootstrap)"
source "$PROJECT_ROOT/scripts/deployment-helpers.sh"
source "$PROJECT_ROOT/test/e2e/scripts/auth_utils.sh"

# --- Configuration (env defaults) ---

SKIP_DEPLOYMENT=${SKIP_DEPLOYMENT:-false}
SKIP_VALIDATION=${SKIP_VALIDATION:-false}
SKIP_AUTH_CHECK=${SKIP_AUTH_CHECK:-true}
INSECURE_HTTP=${INSECURE_HTTP:-false}
EXTERNAL_OIDC=${EXTERNAL_OIDC:-false}

export MAAS_API_IMAGE=${MAAS_API_IMAGE:-}
export MAAS_CONTROLLER_IMAGE=${MAAS_CONTROLLER_IMAGE:-}
export AI_GATEWAY_OPERATOR_IMAGE=${AI_GATEWAY_OPERATOR_IMAGE:-}
export OPERATOR_CATALOG=${OPERATOR_CATALOG:-}
export OPERATOR_IMAGE=${OPERATOR_IMAGE:-}
DEPLOY_MODE=${DEPLOY_MODE:-kustomize}
export POLICY_ENGINE="${POLICY_ENGINE:-rhcl}"
export RHCL_NAMESPACE="${RHCL_NAMESPACE:-kuadrant-system}"
export RHCL_STARTING_CSV="${RHCL_STARTING_CSV:-}"

if [[ "${SKIP_DEPLOYMENT}" == "true" ]]; then
    AUTHORINO_NAMESPACE="$(resolve_authorino_namespace)"
else
    AUTHORINO_NAMESPACE="$(resolve_authorino_namespace "$POLICY_ENGINE")"
fi
export AUTHORINO_NAMESPACE

DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-opendatahub}"
MAAS_SUBSCRIPTION_NAMESPACE="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-llm}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
INGRESS_MODE="${INGRESS_MODE:-clusterip}"
export INGRESS_MODE
GATEWAY_PROGRAMMED_TIMEOUT="${GATEWAY_PROGRAMMED_TIMEOUT:-600}"
OIDC_READINESS_STRICT="${OIDC_READINESS_STRICT:-true}"
ENABLE_TENANT_NAMESPACE_DISCOVERY="${ENABLE_TENANT_NAMESPACE_DISCOVERY:-true}"
AITENANT_NAMESPACE="${AITENANT_NAMESPACE:-ai-tenants}"
ARTIFACTS_DIR="${ARTIFACT_DIR:-${ARTIFACTS:-${LOG_DIR:-$PROJECT_ROOT/test/e2e/reports}}}"

# Resolve infrastructure namespace (maas-api deploys here)
MAAS_API_DEPLOYMENT_NAMESPACE="$(resolve_infra_namespace "${INFRA_NAMESPACE:-AUTO}" "$DEPLOYMENT_NAMESPACE")"
export MAAS_API_DEPLOYMENT_NAMESPACE

# Export all vars that child scripts need
export PROJECT_ROOT SKIP_DEPLOYMENT SKIP_VALIDATION INSECURE_HTTP EXTERNAL_OIDC
export DEPLOYMENT_NAMESPACE MAAS_SUBSCRIPTION_NAMESPACE MODEL_NAMESPACE
export GATEWAY_NAMESPACE GATEWAY_NAME GATEWAY_PROGRAMMED_TIMEOUT
export OIDC_READINESS_STRICT ENABLE_TENANT_NAMESPACE_DISCOVERY AITENANT_NAMESPACE
export ARTIFACTS_DIR DEPLOY_MODE SKIP_AUTH_CHECK

# --- Utility ---

print_header() {
    echo ""
    echo "----------------------------------------"
    echo "$1"
    echo "----------------------------------------"
    echo ""
}

# --- OIDC helpers (needed by deploy_maas_platform) ---

apply_default_oidc_for_keycloak() {
    local keycloak_host="keycloak.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
    export OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-https://${keycloak_host}/realms/tenant-a}"
    export OIDC_TOKEN_URL="${OIDC_TOKEN_URL:-${OIDC_ISSUER_URL}/protocol/openid-connect/token}"
    export OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-test-client}"
    export OIDC_USERNAME="${OIDC_USERNAME:-alice_lead}"
    export OIDC_PASSWORD="${OIDC_PASSWORD:-letmein}"
    export OIDC_USERNAME_NO_ACCESS="${OIDC_USERNAME_NO_ACCESS:-bob_viewer}"
    export OIDC_PASSWORD_NO_ACCESS="${OIDC_PASSWORD_NO_ACCESS:-letmein}"
    local keycloak_host_b="keycloak.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
    export OIDC_TOKEN_URL_TENANT_B="${OIDC_TOKEN_URL_TENANT_B:-https://${keycloak_host_b}/realms/tenant-b/protocol/openid-connect/token}"
}

require_external_oidc_config() {
    local missing=()
    [[ -z "${OIDC_ISSUER_URL:-}" ]] && missing+=("OIDC_ISSUER_URL")
    [[ -z "${OIDC_TOKEN_URL:-}" ]] && missing+=("OIDC_TOKEN_URL")
    [[ -z "${OIDC_CLIENT_ID:-}" ]] && missing+=("OIDC_CLIENT_ID")
    [[ -z "${OIDC_USERNAME:-}" ]] && missing+=("OIDC_USERNAME")
    [[ -z "${OIDC_PASSWORD:-}" ]] && missing+=("OIDC_PASSWORD")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ ERROR: Missing OIDC env vars: ${missing[*]}"
        exit 1
    fi
}

# --- Prerequisites ---

check_prerequisites() {
    echo "Checking prerequisites..."
    if ! oc whoami &>/dev/null; then
        echo "❌ ERROR: Not logged in to OpenShift. Run 'oc login' first."
        exit 1
    fi
    if ! oc auth can-i create namespace &>/dev/null; then
        echo "❌ ERROR: Insufficient cluster privileges. Need cluster-admin."
        exit 1
    fi
    local api_url
    api_url=$(oc whoami --show-server)
    if ! [[ "$api_url" =~ \.openshift\. ]] && ! oc get clusterversion &>/dev/null 2>&1; then
        echo "⚠️  WARNING: This may not be an OpenShift cluster"
    fi
    echo "✅ Prerequisites OK (user: $(oc whoami), server: $api_url)"
}

# --- Deploy platform (calls deploy.sh with flags) ---

deploy_maas_platform() {
    echo "Deploying MaaS platform via ODH operator..."
    echo "Gateway ingress mode: ${INGRESS_MODE}, Deploy mode: ${DEPLOY_MODE}"

    # 1. Install cert-manager and LeaderWorkerSet
    if ! bash "$PROJECT_ROOT/.github/hack/install-cert-manager-and-lws.sh"; then
        echo "❌ ERROR: cert-manager/LWS installation failed"; exit 1
    fi

    # 2. Install ODH operator (kustomize mode only; operator mode handles this in deploy.sh)
    if [[ "${DEPLOY_MODE}" == "kustomize" ]]; then
        if ! bash "$PROJECT_ROOT/.github/hack/install-odh.sh"; then
            echo "❌ ERROR: ODH installation failed"; exit 1
        fi
    else
        echo "Skipping standalone ODH install (DEPLOY_MODE=${DEPLOY_MODE})"
    fi

    # OIDC setup
    if [[ "${EXTERNAL_OIDC}" == "true" ]]; then
        apply_default_oidc_for_keycloak
        require_external_oidc_config
        export OIDC_ISSUER_URL OIDC_TOKEN_URL OIDC_CLIENT_ID OIDC_USERNAME OIDC_PASSWORD
    fi

    # 3. Deploy MaaS via deploy.sh
    export DB_SSLMODE="${DB_SSLMODE:-disable}"
    export MODEL_NAMESPACE
    local deploy_cmd=(
        "$PROJECT_ROOT/scripts/deploy.sh"
        --deployment-mode "${DEPLOY_MODE}"
        --policy-engine "${POLICY_ENGINE}"
    )
    [[ -n "${OPERATOR_CATALOG:-}" ]] && deploy_cmd+=(--operator-catalog "${OPERATOR_CATALOG}")
    [[ -n "${OPERATOR_IMAGE:-}" ]] && deploy_cmd+=(--operator-image "${OPERATOR_IMAGE}")
    [[ "$INSECURE_HTTP" == "true" ]] && deploy_cmd+=(--disable-tls-backend)
    [[ "${EXTERNAL_OIDC}" == "true" ]] && deploy_cmd+=(--external-oidc --enable-keycloak)

    if ! "${deploy_cmd[@]}"; then
        echo "❌ ERROR: MaaS platform deployment failed"; exit 1
    fi

    # 4. Post-deploy: Keycloak test realms + Authorino CA mount
    if [[ "${EXTERNAL_OIDC}" == "true" ]]; then
        if ! bash "$PROJECT_ROOT/docs/samples/install/keycloak/test-realms/apply-test-realms.sh"; then
            echo "❌ ERROR: Keycloak test realm import failed"; exit 1
        fi

        local ingress_cert_name
        ingress_cert_name=$(oc get ingresscontroller default -n openshift-ingress-operator \
            -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
        if [[ -n "$ingress_cert_name" ]]; then
            local ca_tmp; ca_tmp=$(mktemp)
            if oc get secret "$ingress_cert_name" -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d > "$ca_tmp" 2>/dev/null && [[ -s "$ca_tmp" ]]; then
                kubectl create configmap authorino-oidc-ca -n "$AUTHORINO_NAMESPACE" \
                    --from-file=ca.crt="$ca_tmp" --dry-run=client -o yaml | kubectl apply -f -
                oc patch deployment authorino -n "$AUTHORINO_NAMESPACE" --type=json -p '[
                  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
                    "name": "oidc-ca", "configMap": {"name": "authorino-oidc-ca"}
                  }},
                  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {
                    "name": "oidc-ca", "mountPath": "/etc/ssl/certs/oidc-ca.crt",
                    "subPath": "ca.crt", "readOnly": true
                  }}
                ]' 2>/dev/null || echo "⚠️  Authorino CA volume may already be mounted"
                oc rollout status deployment/authorino -n "$AUTHORINO_NAMESPACE" --timeout=120s
            fi
            rm -f "$ca_tmp"
        fi
    fi

    # 5. Wait for DSC and Authorino
    wait_datasciencecluster_ready "default-dsc" "$CUSTOM_RESOURCE_TIMEOUT" || \
        echo "⚠️  WARNING: DataScienceCluster readiness check had issues"

    if [[ "${SKIP_AUTH_CHECK}" != "true" ]]; then
        wait_authorino_ready "$AUTHORINO_NAMESPACE" "$AUTHORINO_TIMEOUT" || \
            echo "⚠️  WARNING: Authorino readiness check had issues"
    else
        echo "⚠️  Skipping Authorino readiness check (SKIP_AUTH_CHECK=true)"
    fi

    echo "✅ MaaS platform deployment completed"
}

# --- Setup test variables ---

setup_vars_for_tests() {
    K8S_CLUSTER_URL=$(oc whoami --show-server)
    export K8S_CLUSTER_URL
    export INSECURE_HTTP EXTERNAL_OIDC
    export CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
    export HOST="maas.${CLUSTER_DOMAIN}"

    if [[ "${EXTERNAL_OIDC}" == "true" ]]; then
        apply_default_oidc_for_keycloak
        require_external_oidc_config
        export OIDC_ISSUER_URL OIDC_TOKEN_URL OIDC_CLIENT_ID OIDC_USERNAME OIDC_PASSWORD
    fi

    if [[ "$INSECURE_HTTP" == "true" ]]; then
        export MAAS_API_BASE_URL="http://${HOST}/maas-api"
    else
        export MAAS_API_BASE_URL="https://${HOST}/maas-api"
    fi
    echo "HOST=${HOST} MAAS_API_BASE_URL=${MAAS_API_BASE_URL}"
}

# --- Validate deployment ---

validate_deployment() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        echo "⏭️  Skipping validation"
        return 0
    fi
    if ! "$PROJECT_ROOT/scripts/validate-deployment.sh"; then
        echo "⚠️  First validation attempt failed, retrying in 30s..."
        sleep 30
        if ! "$PROJECT_ROOT/scripts/validate-deployment.sh"; then
            echo "❌ ERROR: Deployment validation failed after retry"; exit 1
        fi
    fi
    echo "✅ Deployment validation completed"
}

# --- Exit trap: artifact collection ---

_run_exit_artifacts() {
    local exit_code=$?
    set +e
    DEPLOYMENT_NAMESPACE="$DEPLOYMENT_NAMESPACE" \
    MAAS_SUBSCRIPTION_NAMESPACE="$MAAS_SUBSCRIPTION_NAMESPACE" \
    AUTHORINO_NAMESPACE="$AUTHORINO_NAMESPACE" \
    ARTIFACTS_DIR="$ARTIFACTS_DIR" \
        collect_e2e_artifacts
    echo ""
    echo "========== Auth Debug Report =========="
    mkdir -p "$ARTIFACTS_DIR"
    DEPLOYMENT_NAMESPACE="$DEPLOYMENT_NAMESPACE" \
    MAAS_SUBSCRIPTION_NAMESPACE="$MAAS_SUBSCRIPTION_NAMESPACE" \
    AUTHORINO_NAMESPACE="$AUTHORINO_NAMESPACE" \
        run_auth_debug_report 2>&1 | tee "$ARTIFACTS_DIR/auth-debug.log"
    echo "======================================"
    exit $exit_code
}
trap '_run_exit_artifacts' EXIT

# =============================================================================
# Main execution: prereqs → deploy → models → tokens → validate → tests
# =============================================================================

print_header "1. Prerequisites"
check_prerequisites

if [[ "$SKIP_DEPLOYMENT" == "true" ]]; then
    echo "  Skipping deployment (SKIP_DEPLOYMENT=true)"
else
    print_header "2. Deploy MaaS Platform"
    deploy_maas_platform

    print_header "3. Deploy Models"
    bash "$PROJECT_ROOT/test/e2e/scripts/deploy-models.sh"
    patch_authorino_debug  # from auth_utils.sh
fi

print_header "4. Setup Test Variables"
setup_vars_for_tests

print_header "5. Setup Test Tokens"
source "$PROJECT_ROOT/test/e2e/scripts/setup-test-tokens.sh"

print_header "6. Validate Deployment"
validate_deployment

print_header "7. Run E2E Tests"
bash "$PROJECT_ROOT/test/e2e/scripts/run-prow-tests.sh"

echo "🎉 E2E pipeline completed successfully!"
