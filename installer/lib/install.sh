#!/bin/bash
# ============================================================================
# F5 AI Guardrails — Installation Logic
# ============================================================================

detect_gpu_tolerations() {
  if [[ -n "${GPU_TOLERATIONS:-}" ]]; then
    echo "$GPU_TOLERATIONS"
    return
  fi

  local taint_keys
  taint_keys=$(oc get nodes -o json 2>/dev/null | \
    jq -r '[.items[] | select(.status.allocatable["nvidia.com/gpu"] != null and (.status.allocatable["nvidia.com/gpu"] | tonumber) > 0) | .spec.taints[]? | select(.effect == "NoSchedule") | .key] | unique | .[]' 2>/dev/null || true)

  if [[ -z "$taint_keys" ]]; then
    taint_keys="nvidia.com/gpu"
  fi

  local tolerations="["
  local first=true
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if $first; then
      first=false
    else
      tolerations+=","
    fi
    tolerations+="{\"key\":\"$key\",\"effect\":\"NoSchedule\",\"operator\":\"Exists\"}"
  done <<< "$taint_keys"
  tolerations+="]"

  echo "$tolerations"
}

tolerations_to_helm_sets() {
  local json=$1
  local prefix=$2
  local count
  count=$(echo "$json" | jq 'length' 2>/dev/null || echo "0")

  local args=""
  local i=0
  while [[ $i -lt $count ]]; do
    local key effect operator
    key=$(echo "$json" | jq -r ".[$i].key" 2>/dev/null)
    effect=$(echo "$json" | jq -r ".[$i].effect" 2>/dev/null)
    operator=$(echo "$json" | jq -r ".[$i].operator" 2>/dev/null)
    args+=" --set ${prefix}[$i].key=$key --set ${prefix}[$i].effect=$effect --set ${prefix}[$i].operator=$operator"
    i=$((i + 1))
  done

  echo "$args"
}

deploy_quickstart() {
  local ns="$TARGET_NAMESPACE"

  # Create RAG namespace
  log_status "running" "deploying" "Creating namespace $ns..."
  oc create namespace "$ns" 2>/dev/null || true
  oc label namespace "$ns" modelmesh-enabled=false --overwrite 2>/dev/null || true

  # Update Helm dependencies for RAG chart
  log_status "running" "deploying" "Updating Helm chart dependencies..."
  helm dependency update /installer/charts/rag 2>/dev/null || true
  helm dependency build /installer/charts/rag

  # Delete stale jobs in namespace
  oc delete jobs -n "$ns" --all 2>/dev/null || true

  # Build RAG Helm arguments
  local helm_args="-f /installer/charts/rag-values.yaml"

  if [[ -n "${HF_TOKEN:-}" ]]; then
    helm_args+=" --set llm-service.secret.hf_token=$HF_TOKEN"
  fi

  if [[ -n "${LLM:-}" ]]; then
    log_status "running" "deploying" "Enabling LLM model: $LLM"
    helm_args+=" --set global.models.${LLM}.enabled=true"
  fi

  if [[ -n "${SAFETY:-}" ]]; then
    log_status "running" "deploying" "Enabling SAFETY model: $SAFETY"
    helm_args+=" --set global.models.${SAFETY}.enabled=true"
  fi

  if [[ -n "${DEVICE:-}" ]]; then
    helm_args+=" --set llm-service.device=$DEVICE"
  fi

  # Auto-detect GPU tolerations
  local gpu_tolerations
  gpu_tolerations=$(detect_gpu_tolerations)

  if [[ -n "${LLM:-}" ]]; then
    local llm_tol_args
    llm_tol_args=$(tolerations_to_helm_sets "$gpu_tolerations" "global.models.${LLM}.tolerations")
    helm_args+="$llm_tol_args"
  fi

  if [[ -n "${SAFETY:-}" ]]; then
    local safety_tol_args
    safety_tol_args=$(tolerations_to_helm_sets "$gpu_tolerations" "global.models.${SAFETY}.tolerations")
    helm_args+="$safety_tol_args"
  fi

  # Install RAG chart
  log_status "running" "deploying" "Installing RAG Helm chart..."
  eval helm -n "$ns" upgrade --install rag /installer/charts/rag -n "$ns" $helm_args

  log_status "running" "deploying" "Waiting for llamastack rollout (up to 15 minutes)..."
  oc rollout status deploy/llamastack -n "$ns" --timeout=900s

  log_status "running" "deploying" "RAG chart installed successfully"

  # Install F5 AI Security chart (unless skipped)
  if [[ "${SKIP_F5_GUARDRAILS:-}" == "1" ]]; then
    log_status "running" "deploying" "SKIP_F5_GUARDRAILS=1; skipping F5 AI Security chart."
    return
  fi

  install_f5_ai_security "$ns"
}

install_f5_ai_security() {
  local rag_ns=$1
  local f5_ns="${F5_AI_SECURITY_NAMESPACE:-f5-ai-sec}"
  local mod_ns="${F5_MODERATOR_NS:-cai-moderator}"
  local prefect_ns="${F5_PREFECT_NS:-prefect}"
  local inf_ns="${F5_INFERENCE_NS:-f5-ai-sec-inference}"

  log_status "running" "deploying" "Installing F5 AI Security chart (operator ns: $f5_ns)..."

  if [[ ! -f /installer/charts/f5-ai-security-values.yaml ]]; then
    log_error "Missing f5-ai-security-values.yaml."
  fi

  # Build F5 Helm arguments
  local f5_helm_extras=""
  f5_helm_extras+=" --set-string productNamespaces.operator=$f5_ns"
  f5_helm_extras+=" --set-string productNamespaces.moderator=$mod_ns"
  f5_helm_extras+=" --set-string productNamespaces.prefect=$prefect_ns"
  f5_helm_extras+=" --set-string productNamespaces.inference=$inf_ns"
  f5_helm_extras+=" --set namespaces.manageOperatorNamespace=false"

  # Auto-compute Moderator host from cluster ingress
  if [[ "${MODERATOR_HOST_AUTO:-true}" != "false" ]]; then
    local prefix="${MODERATOR_HOST_PREFIX:-aisec}"
    local domain
    domain=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
    if [[ -z "$domain" ]]; then
      log_error "MODERATOR_HOST_AUTO is true but ingress.config/cluster .spec.domain is empty."
    fi
    local host="${prefix}.${domain}"
    log_status "running" "deploying" "Moderator URL: https://$host"
    f5_helm_extras+=" --set-string routes.hostname=$host --set-string securityOperator.moderator.baseUrl=https://$host"
  fi

  # Pass credential env vars if set
  if [[ -n "${DOCKER_USERNAME:-}" ]]; then f5_helm_extras+=" --set-string registry.username=${DOCKER_USERNAME}"; fi
  if [[ -n "${DOCKER_PASSWORD:-}" ]]; then f5_helm_extras+=" --set-string registry.password=${DOCKER_PASSWORD}"; fi
  if [[ -n "${DOCKER_EMAIL:-}" ]]; then f5_helm_extras+=" --set-string registry.email=${DOCKER_EMAIL}"; fi
  if [[ -n "${F5_LICENSE:-}" ]]; then f5_helm_extras+=" --set-string securityOperator.moderator.license=${F5_LICENSE}"; fi

  # First Helm pass — installs Subscription, namespaces, RBAC
  log_status "running" "deploying" "F5 AI Security chart — first pass (Helm --create-namespace; retries if API race)..."
  local attempt=1
  local max_attempts="${F5_HELM_MAX_ATTEMPTS:-8}"
  local retry_sleep="${F5_HELM_RETRY_SLEEP:-6}"
  while [[ $attempt -le $max_attempts ]]; do
    if eval helm upgrade --install f5-ai-security /installer/charts/f5-ai-security \
        -n "$f5_ns" --create-namespace \
        --take-ownership \
        -f /installer/charts/f5-ai-security-values.yaml $f5_helm_extras; then
      break
    fi
    if [[ $attempt -eq $max_attempts ]]; then
      log_error "F5 Helm install failed after $max_attempts attempts."
    fi
    log_status "running" "deploying" "Helm retry $attempt/$max_attempts..."
    attempt=$((attempt + 1))
    sleep "$retry_sleep"
  done

  # Wait for operator CSV
  local operator_csv="${OPERATOR_CSV:-f5-ai-security-operator.v0.8.1}"
  log_status "running" "deploying" "Waiting for operator CSV $operator_csv (best-effort, 600s)..."
  oc wait "csv/$operator_csv" -n "$f5_ns" --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s 2>/dev/null || \
    log_status "running" "deploying" "CSV not Succeeded yet. Continuing..."

  # Wait for SecurityOperator CRD
  log_status "running" "deploying" "Waiting for SecurityOperator CRD (up to 120s)..."
  local w=0
  while [[ $w -lt 60 ]]; do
    if oc get crd securityoperators.ai.security.f5.com >/dev/null 2>&1; then
      log_status "running" "deploying" "CRD securityoperators.ai.security.f5.com is present"
      break
    fi
    w=$((w + 1))
    sleep 2
  done

  # Pre-apply inference model SCC (operator SA cannot create SCCs)
  if oc get scc restricted-v2 >/dev/null 2>&1; then
    if [[ -f /installer/charts/f5-ai-security/extras/openshift-inference-models-scc.yaml ]]; then
      log_status "running" "deploying" "Applying Inference OpenShift SCC..."
      local inf_release="${F5_INFERENCE_HELM_RELEASE:-f5-ai-sec-inference}"
      sed -e "s|__F5_INFERENCE_NAMESPACE__|${inf_ns}|g" \
          -e "s|__F5_INFERENCE_HELM_RELEASE_NAME__|${inf_release}|g" \
          -e "s|__F5_INFERENCE_HELM_RELEASE_NAMESPACE__|${inf_ns}|g" \
          /installer/charts/f5-ai-security/extras/openshift-inference-models-scc.yaml | oc apply -f -
    fi
  fi

  # Second Helm pass — now creates SecurityOperator CR since CRD is registered
  log_status "running" "deploying" "F5 AI Security chart — second pass (SecurityOperator CR)..."
  local r2=1
  while [[ $r2 -le 5 ]]; do
    if eval helm upgrade --install f5-ai-security /installer/charts/f5-ai-security \
        -n "$f5_ns" --create-namespace \
        --take-ownership \
        -f /installer/charts/f5-ai-security-values.yaml $f5_helm_extras; then
      break
    fi
    if [[ $r2 -eq 5 ]]; then
      log_error "Second F5 Helm apply failed after 5 attempts."
    fi
    log_status "running" "deploying" "Second Helm apply retry $r2/5..."
    r2=$((r2 + 1))
    sleep "$retry_sleep"
  done

  log_status "running" "deploying" "F5 AI Security chart applied successfully"
}

check_deployment_status() {
  local ns="$TARGET_NAMESPACE"
  local f5_ns="${F5_AI_SECURITY_NAMESPACE:-f5-ai-sec}"
  local mod_ns="${F5_MODERATOR_NS:-cai-moderator}"
  local prefect_ns="${F5_PREFECT_NS:-prefect}"
  local inf_ns="${F5_INFERENCE_NS:-f5-ai-sec-inference}"

  log_status "running" "checking-status" "Checking RAG pods in $ns..."
  oc get pods -n "$ns" 2>/dev/null || true

  if [[ "${SKIP_F5_GUARDRAILS:-}" != "1" ]]; then
    for check_ns in "$f5_ns" "$mod_ns" "$prefect_ns" "$inf_ns"; do
      if oc get namespace "$check_ns" >/dev/null 2>&1; then
        log_status "running" "checking-status" "Checking pods in $check_ns..."
        oc get pods -n "$check_ns" 2>/dev/null || true
      fi
    done
  fi
}

get_endpoints() {
  local ns="$TARGET_NAMESPACE"
  local mod_ns="${F5_MODERATOR_NS:-cai-moderator}"
  local endpoints="["
  local first=true

  # RAG route
  local rag_route
  rag_route=$(oc get routes -n "$ns" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [[ -n "$rag_route" ]]; then
    endpoints+="{\"name\":\"RAG UI\",\"url\":\"https://$rag_route\"}"
    first=false
  fi

  # Moderator route
  local mod_route
  mod_route=$(oc get route cai-moderator-ui -n "$mod_ns" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$mod_route" ]]; then
    if ! $first; then endpoints+=","; fi
    endpoints+="{\"name\":\"F5 AI Guardrails Moderator\",\"url\":\"https://$mod_route\"}"
    first=false
  fi

  # LlamaStack route
  local ls_route
  ls_route=$(oc get routes -n "$ns" -l app=llamastack -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
  if [[ -n "$ls_route" ]]; then
    if ! $first; then endpoints+=","; fi
    endpoints+="{\"name\":\"LlamaStack\",\"url\":\"https://$ls_route\"}"
  fi

  endpoints+="]"
  echo "$endpoints"
}
