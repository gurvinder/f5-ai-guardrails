#!/bin/bash
# ============================================================================
# F5 AI Guardrails Installer — Deploy Script (Navigator Proxy)
# ============================================================================

set -euo pipefail

# Configuration
REGISTRY="quay.io/rh-ai-quickstart"
IMAGE_NAME="f5-ai-guardrails-installer"
VERSION="1.0.0"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

# ============================================================================
# DO NOT MODIFY: Job deployment function
# ============================================================================

deploy_job() {
  local ACTION=$1
  local TARGET_NAMESPACE=$2
  local EXTRA_ENV=$3

  local INSTALLER_NAMESPACE="default"

  # --------------------------------------------------------------------------
  # Create RBAC for installer
  # --------------------------------------------------------------------------
  info "Creating installer RBAC..."

  cat <<RBAC | oc apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: f5-ai-guardrails-installer
  namespace: ${INSTALLER_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: f5-ai-guardrails-installer
  namespace: ${INSTALLER_NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["pods", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: f5-ai-guardrails-installer
  namespace: ${INSTALLER_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: f5-ai-guardrails-installer
subjects:
  - kind: ServiceAccount
    name: f5-ai-guardrails-installer
    namespace: ${INSTALLER_NAMESPACE}
RBAC

  cat <<RBAC | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: f5-ai-guardrails-installer-${TARGET_NAMESPACE}
rules:
  # Cluster-scoped read permissions for prerequisites checking
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list"]
  - apiGroups: ["config.openshift.io"]
    resources: ["clusterversions", "ingresses"]
    verbs: ["get", "list"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list"]
  - apiGroups: ["packages.operators.coreos.com"]
    resources: ["packagemanifests"]
    verbs: ["get", "list"]
  - apiGroups: ["machineconfiguration.openshift.io"]
    resources: ["machineconfigpools"]
    verbs: ["get", "list"]
  - apiGroups: ["tuned.openshift.io"]
    resources: ["tuneds"]
    verbs: ["get", "list"]
  # Namespace management
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create", "delete", "watch"]
  # Namespace-scoped resources (all namespaces via ClusterRoleBinding)
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services", "endpoints", "configmaps", "secrets", "persistentvolumeclaims", "serviceaccounts", "events"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "replicasets", "daemonsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["route.openshift.io"]
    resources: ["routes"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # RBAC (Helm charts include Role/RoleBinding/ClusterRole/ClusterRoleBinding)
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # OLM Operator management
  - apiGroups: ["operators.coreos.com"]
    resources: ["subscriptions", "operatorgroups", "clusterserviceversions", "installplans"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # F5 AI Security CRDs
  - apiGroups: ["ai.security.f5.com"]
    resources: ["securityoperators"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # KServe CRDs (for status checking)
  - apiGroups: ["serving.kserve.io"]
    resources: ["inferenceservices", "servingruntimes"]
    verbs: ["get", "list", "watch"]
  # OpenShift SCC (for inference model SCC pre-apply)
  - apiGroups: ["security.openshift.io"]
    resources: ["securitycontextconstraints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # Helm release management
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: f5-ai-guardrails-installer-${TARGET_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: f5-ai-guardrails-installer-${TARGET_NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: f5-ai-guardrails-installer
    namespace: ${INSTALLER_NAMESPACE}
RBAC

  # --------------------------------------------------------------------------
  # Create and monitor the Job
  # --------------------------------------------------------------------------

  local ACTION_SHORT=$(echo $ACTION | tr '[:upper:]' '[:lower:]' | tr '_' '-')
  local TIMESTAMP=$(date +%s | tail -c 7)
  local JOB_NAME="f5ag-installer-${ACTION_SHORT}-${TIMESTAMP}"

  info "Creating installer Job: $JOB_NAME"
  info "Action: $ACTION"
  info "Target namespace: $TARGET_NAMESPACE"
  info "Installer namespace: $INSTALLER_NAMESPACE"
  info "Image: ${FULL_IMAGE}"

  cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${INSTALLER_NAMESPACE}
  labels:
    app: f5-ai-guardrails-installer
    action: $(echo $ACTION | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    target-namespace: ${TARGET_NAMESPACE}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: f5-ai-guardrails-installer
        action: $(echo $ACTION | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    spec:
      restartPolicy: Never
      serviceAccountName: f5-ai-guardrails-installer
      containers:
      - name: installer
        image: ${FULL_IMAGE}
        imagePullPolicy: Always
        terminationMessagePolicy: FallbackToLogsOnError
        env:
        - name: ACTION
          value: "${ACTION}"
        - name: TARGET_NAMESPACE
          value: "${TARGET_NAMESPACE}"
        - name: JOB_NAME
          value: "${JOB_NAME}"
${EXTRA_ENV}
EOF

  echo ""
  info "Job created! Monitoring logs..."
  echo ""

  sleep 3
  oc logs -n "$INSTALLER_NAMESPACE" -f "job/${JOB_NAME}" 2>/dev/null || {
    warn "Job may still be starting. Check logs with:"
    echo "  oc logs -n $INSTALLER_NAMESPACE -f job/${JOB_NAME}"
  }

  # --------------------------------------------------------------------------
  # DO NOT MODIFY: Wait for Job completion (poll both Complete and Failed)
  # --------------------------------------------------------------------------
  echo ""
  info "Waiting for Job to complete..."

  WAIT_COUNT=0
  MAX_WAIT=240  # 20 minutes = 240 * 5 seconds
  while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
    JOB_COMPLETE=$(oc get job -n "$INSTALLER_NAMESPACE" "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
    JOB_FAILED=$(oc get job -n "$INSTALLER_NAMESPACE" "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)

    if [[ "$JOB_COMPLETE" == "True" ]]; then
      info "Job completed successfully"
      break
    elif [[ "$JOB_FAILED" == "True" ]]; then
      warn "Job failed. Check logs above for details."
      break
    fi

    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done

  if [[ $WAIT_COUNT -eq $MAX_WAIT ]]; then
    warn "Job did not complete within 20 minutes"
    echo "  Check status: oc get job -n $INSTALLER_NAMESPACE ${JOB_NAME}"
  fi

  # --------------------------------------------------------------------------
  # DO NOT MODIFY: Retrieve termination message
  # --------------------------------------------------------------------------
  TERM_MSG=""
  POD_NAME=$(oc get pods -n "$INSTALLER_NAMESPACE" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -n "$POD_NAME" ]]; then
    TERM_MSG=$(oc get pod -n "$INSTALLER_NAMESPACE" "$POD_NAME" -o jsonpath='{.status.containerStatuses[0].state.terminated.message}' 2>/dev/null)
  fi
  if [[ -z "$TERM_MSG" ]]; then
    TERM_MSG=$(oc get job -n "$INSTALLER_NAMESPACE" "${JOB_NAME}" -o jsonpath='{.metadata.annotations.f5-ai-guardrails-installer/termination-message}' 2>/dev/null)
  fi
  if [[ -n "$TERM_MSG" ]]; then
    echo ""
    info "Termination message:"
    echo "  $TERM_MSG"
  fi

  echo ""
  info "Job complete! Check status with:"
  echo "  oc get job -n $INSTALLER_NAMESPACE ${JOB_NAME}"
  echo "  oc describe job -n $INSTALLER_NAMESPACE ${JOB_NAME}"

  # --------------------------------------------------------------------------
  # DO NOT MODIFY: Clean up all installer RBAC
  # --------------------------------------------------------------------------
  info "Cleaning up installer RBAC..."

  oc delete serviceaccount f5-ai-guardrails-installer -n default --ignore-not-found=true 2>/dev/null || true
  oc delete role f5-ai-guardrails-installer -n default --ignore-not-found=true 2>/dev/null || true
  oc delete rolebinding f5-ai-guardrails-installer -n default --ignore-not-found=true 2>/dev/null || true
  oc delete secret -l "kubernetes.io/service-account.name=f5-ai-guardrails-installer" -n default --ignore-not-found=true 2>/dev/null || true

  oc delete clusterrolebinding "f5-ai-guardrails-installer-${TARGET_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
  oc delete clusterrole "f5-ai-guardrails-installer-${TARGET_NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
}

# ============================================================================
# Main case statement
# ============================================================================

case "${1:-}" in
  check_pre_reqs)
    NAMESPACE="${2:-${NAMESPACE:-}}"
    [[ -z "$NAMESPACE" ]] && error "Namespace required. Usage: ./deploy.sh check_pre_reqs <namespace>"
    deploy_job "CHECK_PRE_REQS" "$NAMESPACE" ""
    ;;

  status)
    NAMESPACE="${2:-${NAMESPACE:-}}"
    [[ -z "$NAMESPACE" ]] && error "Namespace required. Usage: ./deploy.sh status <namespace>"
    deploy_job "STATUS" "$NAMESPACE" ""
    ;;

  install)
    NAMESPACE="${2:-${NAMESPACE:-}}"
    [[ -z "$NAMESPACE" ]] && error "Namespace required. Usage: ./deploy.sh install <namespace>"

    # Prompt for HF token
    echo ""
    read -sp "Enter Hugging Face token (or press Enter to skip): " HF_TOKEN_INPUT
    echo ""

    # Prompt for F5 registry credentials
    read -p "Enter F5 registry username (or press Enter to skip): " DOCKER_USER_INPUT
    if [[ -n "$DOCKER_USER_INPUT" ]]; then
      read -sp "Enter F5 registry password: " DOCKER_PASS_INPUT
      echo ""
      read -p "Enter F5 registry email: " DOCKER_EMAIL_INPUT
    fi

    # Prompt for F5 license
    read -sp "Enter F5 license string (or press Enter to skip): " F5_LIC_INPUT
    echo ""

    # Prompt for GPU taint key override
    echo ""
    echo "GPU taint key configuration:"
    echo "  Enter comma-separated taint keys, or press Enter for auto-detect."
    echo "  Example: nvidia.com/gpu"
    read -p "GPU taint keys: " GPU_TAINT_INPUT

    GPU_TOL_ENV=""
    if [[ -n "$GPU_TAINT_INPUT" ]]; then
      tol_json="["
      first=true
      IFS=',' read -ra TAINT_KEYS <<< "$GPU_TAINT_INPUT"
      for key in "${TAINT_KEYS[@]}"; do
        key=$(echo "$key" | xargs)
        [[ -z "$key" ]] && continue
        if $first; then first=false; else tol_json+=","; fi
        tol_json+="{\"key\":\"$key\",\"effect\":\"NoSchedule\",\"operator\":\"Exists\"}"
      done
      tol_json+="]"
      GPU_TOL_ENV="        - name: GPU_TOLERATIONS
          value: '${tol_json}'"
    fi

    INSTALL_ENV="        - name: INSTALL_MODE
          value: \"demo\""

    if [[ -n "${HF_TOKEN_INPUT:-}" ]]; then
      INSTALL_ENV+="
        - name: HF_TOKEN
          value: \"${HF_TOKEN_INPUT}\""
    fi

    if [[ -n "${DOCKER_USER_INPUT:-}" ]]; then
      INSTALL_ENV+="
        - name: DOCKER_USERNAME
          value: \"${DOCKER_USER_INPUT}\"
        - name: DOCKER_PASSWORD
          value: \"${DOCKER_PASS_INPUT}\"
        - name: DOCKER_EMAIL
          value: \"${DOCKER_EMAIL_INPUT}\""
    fi

    if [[ -n "${F5_LIC_INPUT:-}" ]]; then
      INSTALL_ENV+="
        - name: F5_LICENSE
          value: \"${F5_LIC_INPUT}\""
    fi

    if [[ -n "${GPU_TOL_ENV:-}" ]]; then
      INSTALL_ENV+="
${GPU_TOL_ENV}"
    fi

    deploy_job "INSTALL" "$NAMESPACE" "$INSTALL_ENV"
    ;;

  uninstall_keep_data)
    NAMESPACE="${2:-${NAMESPACE:-}}"
    [[ -z "$NAMESPACE" ]] && error "Namespace required. Usage: ./deploy.sh uninstall_keep_data <namespace>"
    deploy_job "UNINSTALL_KEEP_DATA" "$NAMESPACE" ""
    ;;

  uninstall_delete_all)
    NAMESPACE="${2:-${NAMESPACE:-}}"
    [[ -z "$NAMESPACE" ]] && error "Namespace required. Usage: ./deploy.sh uninstall_delete_all <namespace>"
    deploy_job "UNINSTALL_DELETE_ALL" "$NAMESPACE" ""
    ;;

  upgrade)
    NAMESPACE="${2:-${NAMESPACE:-}}"
    [[ -z "$NAMESPACE" ]] && error "Namespace required. Usage: ./deploy.sh upgrade <namespace>"

    echo ""
    read -sp "Enter Hugging Face token (or press Enter to keep existing): " HF_TOKEN_INPUT
    echo ""

    UPGRADE_ENV="        - name: INSTALL_MODE
          value: \"demo\""

    if [[ -n "${HF_TOKEN_INPUT:-}" ]]; then
      UPGRADE_ENV+="
        - name: HF_TOKEN
          value: \"${HF_TOKEN_INPUT}\""
    fi

    deploy_job "UPGRADE" "$NAMESPACE" "$UPGRADE_ENV"
    ;;

  "")
    echo "F5 AI Guardrails Installer - Deploy Jobs to Cluster"
    echo ""
    echo "Usage: ./deploy.sh <action> <namespace>"
    echo ""
    echo "Actions:"
    echo "  check_pre_reqs <namespace>          - Validate prerequisites"
    echo "  status <namespace>                   - Check deployment status"
    echo "  install <namespace>                  - Deploy installation"
    echo "  uninstall_keep_data <namespace>      - Uninstall (keep data)"
    echo "  uninstall_delete_all <namespace>     - Uninstall (delete all)"
    echo "  upgrade <namespace>                  - Upgrade existing deployment"
    echo ""
    echo "Image: ${FULL_IMAGE}"
    ;;

  *)
    error "Unknown action: $1"
    ;;
esac
