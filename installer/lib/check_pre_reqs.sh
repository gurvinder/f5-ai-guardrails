#!/bin/bash
# ============================================================================
# F5 AI Guardrails — Prerequisites Validation
# ============================================================================

check_prerequisites() {
  local missing=()

  log_status "running" "validating" "Checking OpenShift version..."
  local ocp_version
  ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
  if [[ -z "$ocp_version" ]]; then
    missing+=("{\"name\":\"OpenShift Version\",\"reason\":\"Unable to determine OpenShift version (clusterversion not readable)\"}")
  else
    local ocp_major ocp_minor
    ocp_major=$(echo "$ocp_version" | cut -d. -f1)
    ocp_minor=$(echo "$ocp_version" | cut -d. -f2)
    if [[ "$ocp_major" -lt 4 ]] || { [[ "$ocp_major" -eq 4 ]] && [[ "$ocp_minor" -lt 18 ]]; }; then
      missing+=("{\"name\":\"OpenShift Version\",\"reason\":\"Detected $ocp_version, requires 4.18+\"}")
    else
      log_status "running" "validating" "OpenShift version: $ocp_version (OK)"
    fi
  fi

  log_status "running" "validating" "Checking ingress domain..."
  local ingress_domain
  ingress_domain=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
  if [[ -z "$ingress_domain" ]]; then
    missing+=("{\"name\":\"Ingress Domain\",\"reason\":\"ingress.config/cluster has no .spec.domain\"}")
  else
    log_status "running" "validating" "Ingress domain: $ingress_domain (OK)"
  fi

  log_status "running" "validating" "Checking Node Feature Discovery Operator..."
  if ! oc get crd nodefeatures.nfd.openshift.io >/dev/null 2>&1 && \
     ! oc get crd nodefeatures.nfd.kubernetes.io >/dev/null 2>&1; then
    missing+=("{\"name\":\"Node Feature Discovery Operator\",\"reason\":\"NFD CRD not found. Install Node Feature Discovery Operator from OperatorHub.\"}")
  else
    log_status "running" "validating" "Node Feature Discovery Operator: present (OK)"
  fi

  log_status "running" "validating" "Checking NVIDIA GPU Operator..."
  if ! oc get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
    missing+=("{\"name\":\"NVIDIA GPU Operator\",\"reason\":\"ClusterPolicy CRD not found. Install NVIDIA GPU Operator from OperatorHub and create a ClusterPolicy.\"}")
  else
    log_status "running" "validating" "NVIDIA GPU Operator: present (OK)"
  fi

  log_status "running" "validating" "Checking KServe CRDs..."
  local kserve_ok=true
  for crd in inferenceservices.serving.kserve.io servingruntimes.serving.kserve.io; do
    if ! oc get crd "$crd" >/dev/null 2>&1; then
      missing+=("{\"name\":\"KServe CRD\",\"reason\":\"Missing CRD $crd. Install OpenShift AI / KServe.\"}")
      kserve_ok=false
    fi
  done
  if $kserve_ok; then
    log_status "running" "validating" "KServe CRDs: present (OK)"
  fi

  log_status "running" "validating" "Checking KServe webhook endpoints..."
  local kserve_ns="${KSERVE_WEBHOOK_NAMESPACE:-redhat-ods-applications}"
  local kserve_svc="${KSERVE_WEBHOOK_SERVICE:-kserve-webhook-server-service}"
  local ep
  ep=$(oc get endpoints "$kserve_svc" -n "$kserve_ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
  if [[ -z "$ep" ]]; then
    missing+=("{\"name\":\"KServe Webhook Endpoints\",\"reason\":\"No endpoints for $kserve_ns/$kserve_svc. KServe webhook pods may not be running.\"}")
  else
    log_status "running" "validating" "KServe webhook endpoints: available (OK)"
  fi

  log_status "running" "validating" "Checking F5 AI Security Operator package manifest..."
  if ! oc get packagemanifest f5-ai-security-operator -n openshift-marketplace >/dev/null 2>&1; then
    missing+=("{\"name\":\"F5 AI Security Operator Package\",\"reason\":\"f5-ai-security-operator not found in certified-operators catalog.\"}")
  else
    log_status "running" "validating" "F5 AI Security Operator package: available (OK)"
  fi

  log_status "running" "validating" "Checking default StorageClass..."
  local default_sc
  default_sc=$(oc get storageclass -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' 2>/dev/null | head -1)
  if [[ -z "$default_sc" ]]; then
    missing+=("{\"name\":\"Default StorageClass\",\"reason\":\"No default StorageClass found. Dynamic PVC provisioning required.\"}")
  else
    log_status "running" "validating" "Default StorageClass: $default_sc (OK)"
  fi

  log_status "running" "validating" "Checking Helm version..."
  local helm_version
  helm_version=$(helm version --template='{{.Version}}' 2>/dev/null || echo "")
  if [[ -z "$helm_version" ]]; then
    missing+=("{\"name\":\"Helm CLI\",\"reason\":\"Helm not found or not executable.\"}")
  else
    local helm_minor
    helm_minor=$(echo "$helm_version" | sed 's/v//' | cut -d. -f2)
    if [[ "$helm_minor" -lt 13 ]]; then
      missing+=("{\"name\":\"Helm Version\",\"reason\":\"Detected $helm_version, requires 3.13+ for --take-ownership.\"}")
    else
      log_status "running" "validating" "Helm version: $helm_version (OK)"
    fi
  fi

  log_status "running" "validating" "Checking GPU nodes..."
  local gpu_lines
  gpu_lines=$(oc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | { grep -E '^[1-9]' || true; })
  if [[ -z "$gpu_lines" ]]; then
    missing+=("{\"name\":\"GPU Nodes\",\"reason\":\"No node with allocatable nvidia.com/gpu found. GPU Operator may not have exposed GPUs yet.\"}")
  else
    local gpu_node_count
    gpu_node_count=$(echo "$gpu_lines" | wc -l | tr -d ' ')
    log_status "running" "validating" "GPU nodes: $gpu_node_count node(s) with nvidia.com/gpu (OK)"

    local taint_keys
    taint_keys=$(oc get nodes -o json 2>/dev/null | \
      jq -r '[.items[] | select(.status.allocatable["nvidia.com/gpu"] != null and (.status.allocatable["nvidia.com/gpu"] | tonumber) > 0) | .spec.taints[]? | select(.effect == "NoSchedule") | .key] | unique | .[]' 2>/dev/null || true)
    if [[ -n "$taint_keys" ]]; then
      log_status "running" "validating" "GPU node NoSchedule taints detected: $taint_keys"
    fi
  fi

  log_status "running" "validating" "Checking node resources..."
  local total_cpu total_mem
  total_cpu=$(oc get nodes -o json 2>/dev/null | \
    jq '[.items[].status.allocatable.cpu | if test("m$") then (gsub("m$";"") | tonumber / 1000) else tonumber end] | add | round' 2>/dev/null || echo "0")
  total_mem=$(oc get nodes -o json 2>/dev/null | \
    jq '[.items[].status.allocatable.memory | gsub("Ki$";"") | tonumber / 1048576] | add | round' 2>/dev/null || echo "0")

  if [[ "$total_cpu" -lt 16 ]]; then
    missing+=("{\"name\":\"Node CPU\",\"reason\":\"Total allocatable CPU: ${total_cpu} cores. Minimum 16 vCPUs required.\"}")
  else
    log_status "running" "validating" "Total allocatable CPU: ${total_cpu} cores (OK)"
  fi
  if [[ "$total_mem" -lt 32 ]]; then
    missing+=("{\"name\":\"Node Memory\",\"reason\":\"Total allocatable memory: ${total_mem} GiB. Minimum 32 GiB required.\"}")
  else
    log_status "running" "validating" "Total allocatable memory: ${total_mem} GiB (OK)"
  fi

  log_status "running" "validating" "Checking HugePages configuration..."
  local mcp_exists tuned_exists
  mcp_exists=$(oc get machineconfigpool worker-hp -o name 2>/dev/null || echo "")
  tuned_exists=$(oc get tuned hugepages -n openshift-cluster-node-tuning-operator -o name 2>/dev/null || echo "")

  if [[ -z "$mcp_exists" ]]; then
    missing+=("{\"name\":\"HugePages MachineConfigPool\",\"reason\":\"MachineConfigPool worker-hp not found. Required for F5 XC CE mesh.\"}")
  else
    log_status "running" "validating" "MachineConfigPool worker-hp: present (OK)"
  fi

  if [[ -z "$tuned_exists" ]]; then
    missing+=("{\"name\":\"HugePages Tuned Profile\",\"reason\":\"Tuned profile hugepages not found in openshift-cluster-node-tuning-operator.\"}")
  else
    log_status "running" "validating" "Tuned profile hugepages: present (OK)"
  fi

  local hp_node_label
  hp_node_label=$(oc get nodes -l node-role.kubernetes.io/worker-hp -o name 2>/dev/null || echo "")
  if [[ -z "$hp_node_label" ]]; then
    missing+=("{\"name\":\"HugePages Node Label\",\"reason\":\"No node labeled with node-role.kubernetes.io/worker-hp.\"}")
  else
    log_status "running" "validating" "HugePages node label: present (OK)"

    local hp_alloc
    hp_alloc=$(oc get nodes -l node-role.kubernetes.io/worker-hp -o jsonpath='{.items[0].status.allocatable.hugepages-2Mi}' 2>/dev/null || echo "0")
    if [[ "$hp_alloc" == "0" || -z "$hp_alloc" ]]; then
      missing+=("{\"name\":\"HugePages Allocation\",\"reason\":\"hugepages-2Mi allocatable is 0 on worker-hp node. Node reboot may be required.\"}")
    else
      log_status "running" "validating" "HugePages-2Mi allocatable: $hp_alloc (OK)"
    fi
  fi

  log_status "running" "validating" "Checking architecture..."
  local arch
  arch=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "")
  if [[ "$arch" != "amd64" ]]; then
    missing+=("{\"name\":\"Architecture\",\"reason\":\"Detected $arch, requires x86_64 (amd64).\"}")
  else
    log_status "running" "validating" "Architecture: $arch (OK)"
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    local missing_json
    missing_json=$(printf '%s,' "${missing[@]}")
    missing_json="[${missing_json%,}]"
    log_prerequisites_failed "$missing_json"
    return 2
  fi

  return 0
}
