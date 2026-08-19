#!/bin/bash
# ============================================================================
# F5 AI Guardrails — Uninstallation Logic
# ============================================================================

cleanup_quickstart() {
  local mode=$1
  local ns="$TARGET_NAMESPACE"
  local f5_ns="${F5_AI_SECURITY_NAMESPACE:-f5-ai-sec}"
  local mod_ns="${F5_MODERATOR_NS:-cai-moderator}"
  local prefect_ns="${F5_PREFECT_NS:-prefect}"
  local inf_ns="${F5_INFERENCE_NS:-f5-ai-sec-inference}"
  local operator_sub="${OPERATOR_SUBSCRIPTION:-f5-ai-security-operator}"
  local secop_name="${SECURITYOPERATOR_NAME:-security-operator-demo}"

  # Uninstall RAG Helm release
  log_status "running" "uninstalling" "Uninstalling RAG Helm release..."
  helm -n "$ns" uninstall rag 2>/dev/null || true

  # Handle PVCs based on mode
  if [[ "$mode" == "delete-all" ]]; then
    log_status "running" "uninstalling" "Removing pgvector PVCs from $ns..."
    local pvcs
    pvcs=$(oc get pvc -n "$ns" -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null | { grep -E '^pg-data' || true; })
    if [[ -n "$pvcs" ]]; then
      echo "$pvcs" | while read -r pvc; do
        [[ -n "$pvc" ]] && oc delete pvc -n "$ns" "$pvc" 2>/dev/null || true
      done
    fi
  else
    log_status "running" "uninstalling" "Keeping PVCs in $ns (keep-data mode)"
  fi

  # Delete remaining pods in RAG namespace
  log_status "running" "uninstalling" "Deleting remaining pods in $ns..."
  oc delete pods -n "$ns" --all 2>/dev/null || true

  # Uninstall F5 AI Security Helm release
  log_status "running" "uninstalling" "Removing F5 AI Security Helm release..."
  helm -n "$f5_ns" uninstall f5-ai-security 2>/dev/null || true

  # Remove SecurityOperator CR
  log_status "running" "uninstalling" "Removing SecurityOperator CR..."
  oc delete securityoperator "$secop_name" -n "$mod_ns" --ignore-not-found 2>/dev/null || true

  # Remove operator Subscription
  log_status "running" "uninstalling" "Removing operator Subscription..."
  oc delete subscription "$operator_sub" -n "$f5_ns" --ignore-not-found 2>/dev/null || true

  # Remove operator CSVs
  log_status "running" "uninstalling" "Removing operator CSVs..."
  local csvs
  csvs=$(oc get csv -n "$f5_ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | { grep "^${operator_sub}" || true; })
  if [[ -n "$csvs" ]]; then
    echo "$csvs" | while read -r csv; do
      [[ -n "$csv" ]] && oc delete csv "$csv" -n "$f5_ns" --ignore-not-found 2>/dev/null || true
    done
  fi

  if [[ "$mode" == "delete-all" ]]; then
    # Delete F5 product namespaces
    log_status "running" "uninstalling" "Deleting F5 product namespaces..."
    for del_ns in "$f5_ns" "$mod_ns" "$prefect_ns" "$inf_ns"; do
      local ns_phase
      ns_phase=$(oc get namespace "$del_ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      if [[ "$ns_phase" == "Terminating" ]]; then
        log_status "running" "uninstalling" "Namespace $del_ns already Terminating, skipping delete"
      elif [[ -n "$ns_phase" ]]; then
        oc delete project "$del_ns" --wait=false 2>/dev/null || true
      fi
    done

    # Delete RAG namespace
    log_status "running" "uninstalling" "Deleting RAG namespace $ns..."
    local rag_phase
    rag_phase=$(oc get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$rag_phase" == "Terminating" ]]; then
      log_status "running" "uninstalling" "Namespace $ns already Terminating"
    elif [[ -n "$rag_phase" ]]; then
      oc delete project "$ns" --wait=false 2>/dev/null || true
    fi
  else
    # keep-data: preserve PVCs in F5 namespaces too
    log_status "running" "uninstalling" "Keeping namespaces and PVCs (keep-data mode)"

    # Delete workloads but not PVCs in F5 namespaces
    for del_ns in "$mod_ns" "$prefect_ns" "$inf_ns"; do
      if oc get namespace "$del_ns" >/dev/null 2>&1; then
        log_status "running" "uninstalling" "Removing workloads in $del_ns (keeping PVCs)..."
        oc delete deployments --all -n "$del_ns" 2>/dev/null || true
        oc delete statefulsets --all -n "$del_ns" 2>/dev/null || true
        oc delete pods --all -n "$del_ns" 2>/dev/null || true
      fi
    done
  fi

  log_status "running" "uninstalling" "Uninstall completed (namespaces may stay Terminating until cluster finishes cleanup)"
}
