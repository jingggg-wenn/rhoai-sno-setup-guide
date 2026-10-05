# RHOAI 3.5 SNO Setup Guide

Created: 29 Sep 2026

**한국어 가이드는 [여기](README_KR.md)를 참고하세요.**

Single-script enablement of all Red Hat OpenShift AI 3.5 features on a Single Node OpenShift (SNO) cluster, including Models-as-a-Service (MaaS), observability, and evaluation tooling.

- **Repository:** [https://github.com/jingggg-wenn/rhoai-sno-setup-guide](https://github.com/jingggg-wenn/rhoai-sno-setup-guide)
- **Upstream source:** [https://github.com/hyogrin/RHOAI-Toolkit](https://github.com/hyogrin/RHOAI-Toolkit) (tracked as `upstream` remote)
- **Tested on:** RHOAI v3.5.1 (Sep 2026)

---

## Disclaimer

This is an **unofficial** setup script, not maintained or endorsed by Red Hat. It is tested and maintained on a version-specific basis (currently RHOAI 3.5.1) and may not work on other versions without modification. Use at your own discretion.

---



## Purpose

This is a lightweight repo containing two automation scripts extracted from the [RHOAI-Toolkit](https://github.com/hyogrin/RHOAI-Toolkit). The goal is self-enablement for Red Hat teams (SSA, ASA) and partners who want to quickly set up a fully-featured RHOAI 3.5 environment for demos, testing, or learning.

Instead of manually configuring dozens of operators, dashboard flags, CRDs, and gateway resources one by one, these scripts handle the entire setup in two sequential runs.

---



## Environment Details: GPU and MachineSet

The RHDP demo environment comes with a GPU node already provisioned. This is sufficient for deploying a single model. If you need to deploy additional models concurrently, you may need to create additional GPU MachineSets to provide more GPU capacity.

---



## What Gets Configured



### Script 1: `sno-enable-all-features-35.sh`

Enables all RHOAI 3.5 DSC components and dashboard features in 9 steps:


| Step | What it does                                                                            |
| ---- | --------------------------------------------------------------------------------------- |
| 1    | User Workload Monitoring                                                                |
| 2    | DSC component activation (MLflow, OGX, AIGateway, MaaS)                                 |
| 3    | MLflow server + EvalHub + demo Data Science Project                                     |
| 4    | MaaS Gateway (GatewayClass + Gateway CRs)                                               |
| 5    | Dashboard menu activation (all feature flags)                                           |
| 6    | Operator install (Kueue, cert-manager, LWS, OpenTelemetry, Tempo, COO, RHCL)            |
| 7    | DSCI observability (metrics, traces, MonitoringStack, Perses) + Kuadrant CR + UIPlugins |
| 8    | Dashboard restart                                                                       |
| 9    | Verification                                                                            |




### Script 2: `sno-setup-maas-35.sh`

Configures MaaS infrastructure in 5 steps:


| Step | What it does                                                |
| ---- | ----------------------------------------------------------- |
| 1    | PostgreSQL database (POC deployment or external connection) |
| 2    | Kuadrant CR + Authorino TLS in `kuadrant-system`            |
| 3    | Rate limiting (Redis + EnvoyFilters)                        |
| 4    | Kuadrant AuthPolicy reconciliation                          |
| 5    | Verification                                                |


Both scripts are **idempotent** -- safe to re-run if interrupted or if operators are still installing in the background.

---



## Steps



### Step 1: Order the environment

Go to [Red Hat Demo Platform (RHDP)](https://demo.redhat.com) and order **Red Hat OpenShift AI 3**. Allow time for the environment to fully provision and all nodes to become ready.

![Red Hat OpenShift AI 3 - RHDP Catalog](images/img-red-hat-openshift-ai-3.png)

### Step 2: Log in

Use the credentials provided in your RHDP order confirmation. Log in to the OpenShift console and verify you can access the cluster.

### Step 3: Install Web Terminal

From the OpenShift console:

1. Go to **Ecosystem** > **Software Catalog**
2. Search for **Web Terminal**

![Web Terminal Operator in Software Catalog](images/img-web-terminal-operator.png)

1. Install it with default settings

![Install Web Terminal](images/img-install-web-terminal.png)

1. Once installed, click the **>_** icon in the top-right of the console to open a terminal session

![Open Web Terminal](images/img-initiate-cli.png)

The Web Terminal is where you will run the setup scripts. It comes pre-configured with `oc` already authenticated.

### Step 4: Enable all features

From the Web Terminal (or any terminal with `oc login` completed):

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-sno-setup-guide/main/scripts/sno-enable-all-features-35.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/jingggg-wenn/rhoai-sno-setup-guide.git
cd rhoai-sno-setup-guide
bash scripts/sno-enable-all-features-35.sh
```

> **Tip:** In Web Terminal, RHCL/Service Mesh installation (Step 6) may briefly disconnect your session. If this happens, operators continue installing via OLM in the background. Reconnect and re-run the script -- completed steps are skipped.

> **Sample output:** [sno-all-features-output.txt](sample-output/sno-all-features-output.txt)

### Step 5: Set up MaaS

After Script 1 completes (all operators installed and verified):

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-sno-setup-guide/main/scripts/sno-setup-maas-35.sh | bash
```

Or if you cloned the repo:

```bash
bash scripts/sno-setup-maas-35.sh
```

Options:

```
--postgres-connection <url>   Use an external PostgreSQL instead of the built-in POC instance
--skip-rate-limiting          Skip Redis and EnvoyFilter setup
```

> **Sample output:** [enable-maas-output.txt](sample-output/enable-maas-output.txt)

### Step 6: Deploy a model

Once both scripts complete:

1. Open the RHOAI Dashboard (URL printed at the end of each script)
2. Go to **Gen AI Studio** > **Deploy**
3. Select a model and deploy with the **llm-d** runtime for MaaS integration
4. Register a subscription and auth policy via the Dashboard



### Step 7: Verify MaaS endpoint

```bash
TOKEN=$(oc whoami -t)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk https://maas.${CLUSTER_DOMAIN}/v1/models -H "Authorization: Bearer $TOKEN"
```

---



## Known Issues (RHOAI 3.5.1)

- **Non-streaming chat/completions via MaaS gateway** may return empty (0-byte) responses. This is caused by the `ext_proc` filter's `FULL_DUPLEX_STREAMED` response body mode conflicting with single-body (non-streaming) responses. Streaming (`stream: true`) works correctly. The Playground uses streaming by default and is not affected.

---



## Verification Commands

After running both scripts, use these to check the state of your cluster:

```bash
# RHOAI operator and DSC status
oc get csv -n redhat-ods-operator
oc get datasciencecluster default-dsc

# Operators installed
oc get csv -A | grep -E "nfd|gpu|kueue|lws|rhcl|rhods|cert-manager|tempo|opentelemetry|observability"

# MaaS gateway
oc get gateway -n openshift-ingress

# Dashboard URL
oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}'

# MaaS tenant
oc get tenant -n models-as-a-service

# Kuadrant and Authorino
oc get kuadrant -n kuadrant-system
oc get authorino -n kuadrant-system
```

