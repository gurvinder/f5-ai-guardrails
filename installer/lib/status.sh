#!/bin/bash
# ============================================================================
# F5 AI Guardrails — Deployment Status Verification
# ============================================================================

verify_deployment() {
  local ns="$TARGET_NAMESPACE"
  local f5_ns="${F5_AI_SECURITY_NAMESPACE:-f5-ai-sec}"
  local mod_ns="${F5_MODERATOR_NS:-cai-moderator}"
  local prefect_ns="${F5_PREFECT_NS:-prefect}"
  local inf_ns="${F5_INFERENCE_NS:-f5-ai-sec-inference}"

  # Check RAG namespace
  log_status "running" "verifying" "Checking RAG namespace $ns..."
  local ns_phase
  ns_phase=$(oc get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ -z "$ns_phase" ]]; then
    log_status "running" "verifying" "Namespace $ns does not exist (clean state)"
  elif [[ "$ns_phase" == "Terminating" ]]; then
    log_status "running" "verifying" "Namespace $ns is Terminating"
  else
    log_status "running" "verifying" "Namespace $ns: $ns_phase"

    # Check Helm releases
    local rag_release
    rag_release=$(helm list -n "$ns" -q 2>/dev/null | { grep -E '^rag$' || true; })
    if [[ -n "$rag_release" ]]; then
      log_status "running" "verifying" "RAG Helm release: deployed"
    else
      log_status "running" "verifying" "RAG Helm release: not found"
    fi

    # Report pod status
    report_pod_status "$ns" "RAG"
  fi

  # Check F5 namespaces
  for check_ns_pair in "$f5_ns:F5 Operator" "$mod_ns:Moderator" "$prefect_ns:Prefect" "$inf_ns:Inference"; do
    local check_ns="${check_ns_pair%%:*}"
    local check_label="${check_ns_pair#*:}"

    local check_phase
    check_phase=$(oc get namespace "$check_ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ -z "$check_phase" ]]; then
      log_status "running" "verifying" "$check_label namespace ($check_ns): does not exist"
      continue
    elif [[ "$check_phase" == "Terminating" ]]; then
      log_status "running" "verifying" "$check_label namespace ($check_ns): Terminating"
      continue
    fi

    log_status "running" "verifying" "$check_label namespace ($check_ns): $check_phase"
    report_pod_status "$check_ns" "$check_label"
  done

  # Check F5 Helm release
  local f5_release
  f5_release=$(helm list -n "$f5_ns" -q 2>/dev/null | { grep -E '^f5-ai-security$' || true; })
  if [[ -n "$f5_release" ]]; then
    log_status "running" "verifying" "F5 AI Security Helm release: deployed"
  else
    log_status "running" "verifying" "F5 AI Security Helm release: not found"
  fi

  # Check operator CSV
  local csv_status
  csv_status=$(oc get csv -n "$f5_ns" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null | { grep "f5-ai-security" || true; })
  if [[ -n "$csv_status" ]]; then
    log_status "running" "verifying" "F5 AI Security Operator CSV: $csv_status"
  fi

  # Check routes
  local mod_route
  mod_route=$(oc get route cai-moderator-ui -n "$mod_ns" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$mod_route" ]]; then
    log_status "running" "verifying" "Moderator UI route: https://$mod_route"
  fi

  # Check services
  log_status "running" "verifying" "Checking services in $ns..."
  oc get svc -n "$ns" 2>/dev/null || true

  # Check PVCs
  log_status "running" "verifying" "Checking PVCs in $ns..."
  oc get pvc -n "$ns" 2>/dev/null || true
}

report_pod_status() {
  local ns=$1
  local label=$2

  local pods
  pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null || echo "")
  if [[ -z "$pods" ]]; then
    log_status "running" "verifying" "$label pods: none"
    return
  fi

  local total ready running
  total=$(echo "$pods" | wc -l | tr -d ' ')
  running=$(echo "$pods" | { grep -c "Running" || true; })
  ready=$(echo "$pods" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]!="0") count++} END{print count+0}')

  local failed
  failed=$(echo "$pods" | { grep -E "Error|CrashLoopBackOff|ImagePullBackOff" || true; } | wc -l | tr -d ' ')

  log_status "running" "verifying" "$label pods: $ready/$total ready, $running running, $failed failed"

  if [[ "$failed" -gt 0 ]]; then
    log_status "running" "verifying" "$label — failing pods:"
    echo "$pods" | { grep -E "Error|CrashLoopBackOff|ImagePullBackOff" || true; }
  fi
}
