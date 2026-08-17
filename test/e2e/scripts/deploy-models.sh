#!/bin/bash
# =============================================================================
# Deploy E2E test models (LLMInferenceService + MaaSModelRef + MaaSAuthPolicy + MaaSSubscription)
#
# Called by prow_run_smoke_test.sh after deploy_maas_platform().
# Requires: oc login, PROJECT_ROOT, deployment-helpers.sh sourced.
#
# Environment:
#   PROJECT_ROOT               - repo root (required)
#   GATEWAY_NAME               - gateway resource name (default: maas-default-gateway)
#   GATEWAY_NAMESPACE           - gateway namespace (default: openshift-ingress)
#   GATEWAY_PROGRAMMED_TIMEOUT - seconds to wait for gateway (default: 600)
#   MAAS_SUBSCRIPTION_NAMESPACE - namespace for MaaS CRs (default: models-as-a-service)
#   MODEL_NAMESPACE             - namespace for models (default: llm)
#   DEPLOYMENT_NAMESPACE        - controller namespace (default: opendatahub)
#   LLMIS_TIMEOUT              - LLMInferenceService ready timeout (default: 300)
#   MAASMODELREF_TIMEOUT       - MaaSModelRef ready timeout (default: 300)
#   AUTHPOLICY_TIMEOUT         - AuthPolicy enforced timeout (default: 180)
# =============================================================================

set -euo pipefail

GATEWAY_NAME="${GATEWAY_NAME:-maas-default-gateway}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
GATEWAY_PROGRAMMED_TIMEOUT="${GATEWAY_PROGRAMMED_TIMEOUT:-600}"
MAAS_SUBSCRIPTION_NAMESPACE="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
MODEL_NAMESPACE="${MODEL_NAMESPACE:-llm}"
DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-opendatahub}"
LLMIS_TIMEOUT="${LLMIS_TIMEOUT:-300}"
MAASMODELREF_TIMEOUT="${MAASMODELREF_TIMEOUT:-300}"
AUTHPOLICY_TIMEOUT="${AUTHPOLICY_TIMEOUT:-180}"

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    echo "❌ ERROR: PROJECT_ROOT must be set" >&2
    exit 1
fi

# Source helpers if not already sourced
if ! type wait_for_gateway_programmed &>/dev/null; then
    source "$PROJECT_ROOT/scripts/deployment-helpers.sh"
fi

dump_llmis_diagnostics() {
    local name="$1" ns="$2"
    echo "--- LLMInferenceService $ns/$name diagnostics ---"
    oc get llminferenceservice "$name" -n "$ns" -o yaml 2>/dev/null || true
    echo "--- Pods in $ns ---"
    oc get pods -n "$ns" -o wide 2>/dev/null || true
    echo "--- Events in $ns ---"
    oc get events -n "$ns" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
}

wait_for_auth_policies_enforced() {
    local timeout="$AUTHPOLICY_TIMEOUT"
    echo "Waiting for Kuadrant AuthPolicies to be enforced (timeout: ${timeout}s)..."

    local llm_namespaces
    llm_namespaces=$(oc get llminferenceservices -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
    local namespaces
    namespaces=$(printf '%s\n%s\n' "${GATEWAY_NAMESPACE}" "$llm_namespaces" | sort -u | xargs)

    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        local all_enforced=true
        local total=0
        for ns in $namespaces; do
            while IFS= read -r status; do
                total=$((total + 1))
                if [[ "$status" != "True" ]]; then
                    all_enforced=false
                fi
            done < <(oc get authpolicies -n "$ns" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Enforced")].status}{"\n"}{end}' 2>/dev/null)
        done
        if $all_enforced && [[ $total -gt 0 ]]; then
            echo "✅ All AuthPolicies enforced ($total policies)"
            return 0
        fi
        echo "  Waiting... ($total policies found, not all enforced yet)"
        sleep 10
    done
    echo "⚠️  WARNING: AuthPolicies not all enforced after ${timeout}s, tests may fail"
    oc get authpolicies -A -o wide 2>/dev/null || true
}

# --- Main ---
echo "Deploying MaaS system (free + premium: LLMIS + MaaSModelRef + MaaSAuthPolicy + MaaSSubscription)"

if ! wait_for_gateway_programmed "$GATEWAY_NAME" "$GATEWAY_NAMESPACE" "$GATEWAY_PROGRAMMED_TIMEOUT"; then
    exit 1
fi

# Create namespaces
for ns in "$MODEL_NAMESPACE" "$MAAS_SUBSCRIPTION_NAMESPACE"; do
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Creating '$ns' namespace..."
        if ! kubectl create namespace "$ns"; then
            echo "❌ ERROR: Failed to create '$ns' namespace"
            exit 1
        fi
    else
        echo "'$ns' namespace already exists"
    fi
done

# Deploy all at once so dependencies resolve correctly
if ! (cd "$PROJECT_ROOT" && kustomize build test/e2e/fixtures/ | \
        sed "s/namespace: models-as-a-service/namespace: $MAAS_SUBSCRIPTION_NAMESPACE/g" | \
        kubectl apply -f -); then
    echo "❌ ERROR: Failed to deploy MaaS system with e2e fixtures"
    exit 1
fi
echo "✅ MaaS system deployed (free + premium + e2e test fixtures)"

# Wait for LLMInferenceServices
echo "Waiting for models to be ready (timeout: ${LLMIS_TIMEOUT}s)..."
for model in facebook-opt-125m-simulated premium-simulated-simulated-premium e2e-unconfigured-facebook-opt-125m-simulated; do
    if ! oc wait "llminferenceservice/$model" -n "$MODEL_NAMESPACE" --for=condition=Ready --timeout="${LLMIS_TIMEOUT}s"; then
        echo "❌ ERROR: Timed out after ${LLMIS_TIMEOUT}s waiting for $model to be ready"
        dump_llmis_diagnostics "$model" "$MODEL_NAMESPACE"
        exit 1
    fi
done
echo "✅ Simulator models ready"

# Wait for governed MaaSModelRefs
governed_models=("facebook-opt-125m-simulated" "premium-simulated-simulated-premium")
echo "Waiting for governed MaaSModelRefs to be Ready (timeout: ${MAASMODELREF_TIMEOUT}s)..."
deadline=$((SECONDS + MAASMODELREF_TIMEOUT))
all_ready=false

while [[ $SECONDS -lt $deadline ]]; do
    all_ready=true
    for model in "${governed_models[@]}"; do
        phase=$(oc get maasmodelref "$model" -n "$MODEL_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" != "Ready" ]]; then
            all_ready=false
            break
        fi
    done
    if $all_ready; then
        echo "✅ Governed MaaSModelRefs ready"
        break
    fi
    sleep 5
done

if ! $all_ready; then
    echo "❌ ERROR: Governed MaaSModelRefs did not reach Ready state within ${MAASMODELREF_TIMEOUT}s"
    oc get maasmodelrefs -n "$MODEL_NAMESPACE" -o yaml || true
    kubectl logs deployment/maas-controller -n "$DEPLOYMENT_NAMESPACE" --tail=100 || true
    exit 1
fi

wait_for_auth_policies_enforced
echo "✅ Model deployment complete"
