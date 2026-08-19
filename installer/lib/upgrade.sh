#!/bin/bash
# ============================================================================
# F5 AI Guardrails — Upgrade Logic
# ============================================================================
# Wraps helm upgrade for both charts. For major operator version changes
# (e.g., v0.4.3 alpha → v0.7.0 stable), see docs/upgrading_f5_ai_guardrails.md
# for manual steps (CR migration, channel swap, SCC re-grant).
# ============================================================================

upgrade_quickstart() {
  local ns="$TARGET_NAMESPACE"
  local f5_ns="${F5_AI_SECURITY_NAMESPACE:-f5-ai-sec}"

  # Verify existing deployment
  local rag_release
  rag_release=$(helm list -n "$ns" -q 2>/dev/null | { grep -E '^rag$' || true; })
  if [[ -z "$rag_release" ]]; then
    log_error "No existing RAG Helm release found in $ns. Run INSTALL first."
  fi

  # Update Helm dependencies
  log_status "running" "upgrading" "Updating Helm chart dependencies..."
  helm dependency update /installer/charts/rag 2>/dev/null || true
  helm dependency build /installer/charts/rag

  # Build RAG Helm arguments
  local helm_args="-f /installer/charts/rag-values.yaml"

  if [[ -n "${HF_TOKEN:-}" ]]; then
    helm_args+=" --set llm-service.secret.hf_token=$HF_TOKEN"
  fi

  if [[ -n "${LLM:-}" ]]; then
    helm_args+=" --set global.models.${LLM}.enabled=true"
  fi

  if [[ -n "${SAFETY:-}" ]]; then
    helm_args+=" --set global.models.${SAFETY}.enabled=true"
  fi

  if [[ -n "${DEVICE:-}" ]]; then
    helm_args+=" --set llm-service.device=$DEVICE"
  fi

  # Upgrade RAG chart
  log_status "running" "upgrading" "Upgrading RAG Helm chart..."
  eval helm -n "$ns" upgrade --install rag /installer/charts/rag -n "$ns" $helm_args

  log_status "running" "upgrading" "Waiting for llamastack rollout..."
  oc rollout status deploy/llamastack -n "$ns" --timeout=900s

  log_status "running" "upgrading" "RAG chart upgraded successfully"

  # Upgrade F5 AI Security chart if present
  if [[ "${SKIP_F5_GUARDRAILS:-}" == "1" ]]; then
    log_status "running" "upgrading" "SKIP_F5_GUARDRAILS=1; skipping F5 AI Security upgrade."
    return
  fi

  local f5_release
  f5_release=$(helm list -n "$f5_ns" -q 2>/dev/null | { grep -E '^f5-ai-security$' || true; })
  if [[ -z "$f5_release" ]]; then
    log_status "running" "upgrading" "No F5 AI Security release found. Skipping F5 upgrade."
    return
  fi

  install_f5_ai_security "$ns"
  log_status "running" "upgrading" "F5 AI Security chart upgraded successfully"
}
