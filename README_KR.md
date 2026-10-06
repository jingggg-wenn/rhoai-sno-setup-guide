# RHOAI 3.5 SNO 설정 가이드

작성일: 29 Sep 2026
최종 수정: 06 Oct 2026

Single Node OpenShift (SNO) 클러스터에서 Red Hat OpenShift AI 3.5의 모든 기능을 스크립트 하나로 활성화합니다. Models-as-a-Service (MaaS), 관측성(Observability), 평가 도구(Evaluation tooling)를 포함합니다.

- **리포지토리:** [https://github.com/jingggg-wenn/rhoai-sno-setup-guide](https://github.com/jingggg-wenn/rhoai-sno-setup-guide)
- **업스트림 소스:** [https://github.com/hyogrin/RHOAI-Toolkit](https://github.com/hyogrin/RHOAI-Toolkit) (`upstream` 리모트로 추적)
- **테스트 환경:** RHOAI v3.5.1 (Sep 2026)

---

## 면책 조항

이 설정 스크립트는 **비공식**이며, Red Hat에서 유지보수하거나 보증하지 않습니다. 특정 버전(현재 RHOAI 3.5.1) 기준으로 테스트 및 유지보수되며, 다른 버전에서는 수정 없이 작동하지 않을 수 있습니다. 사용 시 본인의 판단에 따라 진행하시기 바랍니다.

---

## 목적

이 리포지토리는 [RHOAI-Toolkit](https://github.com/hyogrin/RHOAI-Toolkit)에서 추출한 자동화 스크립트를 포함하는 경량 리포지토리입니다. Red Hat 팀(SSA, ASA) 및 파트너가 데모, 테스트, 학습을 위해 RHOAI 3.5 환경의 모든 기능을 빠르게 설정할 수 있도록 셀프 활성화(Self-enablement)를 목표로 합니다.

수십 개의 오퍼레이터, 대시보드 플래그, CRD, 게이트웨이 리소스를 하나하나 수동으로 설정하는 대신, 이 스크립트를 순차적으로 실행하면 전체 설정이 완료됩니다.

---

## 환경 정보: GPU 및 MachineSet

RHDP 데모 환경에는 GPU 노드가 이미 프로비저닝되어 있습니다. 이는 단일 모델 배포에 충분합니다. 여러 모델을 동시에 배포해야 하는 경우 추가 GPU MachineSet을 생성하여 GPU 용량을 확보해야 합니다.

---

## 구성 내용

### 스크립트 1: `sno-enable-all-features-35.sh`

RHOAI 3.5 DSC 컴포넌트 및 대시보드 기능을 활성화합니다:

| 단계 | 내용 |
|------|------|
| 1 | User Workload Monitoring |
| 2 | DSC 컴포넌트 활성화 (MLflow, OGX, AIGateway, MaaS) |
| 3 | MLflow 서버 + EvalHub + demo Data Science Project |
| 4 | MaaS Gateway (GatewayClass + Gateway CR) |
| 5 | 대시보드 메뉴 활성화 (모든 기능 플래그) |
| 5b | Accelerator 메트릭 기록 규칙 (GPU Operator 전제 조건) |
| 5c | Red Hat OpenShift Dev Spaces (오퍼레이터 + CheCluster) |
| 6 | 오퍼레이터 설치 (Kueue, cert-manager, LWS, OpenTelemetry, Tempo, COO, RHCL) |
| 7 | DSCI 관측성 (메트릭, 트레이스, MonitoringStack, Perses) + Kuadrant CR + UIPlugins |
| 8 | 대시보드 재시작 |
| 9 | 검증 |

### 스크립트 2: `sno-setup-maas-35.sh`

MaaS 인프라를 구성합니다:

| 단계 | 내용 |
|------|------|
| 1 | PostgreSQL 데이터베이스 (POC 배포 또는 외부 연결) |
| 2 | Kuadrant CR + Authorino TLS (`kuadrant-system`) |
| 3 | Rate Limiting (Redis + EnvoyFilters) |
| 4 | Kuadrant AuthPolicy 재조정(Reconciliation) |
| 5 | 검증 |

### 워크숍 준비: `scripts/workshop-prep/`

다중 사용자 워크숍을 위한 클러스터 준비 스크립트(선택 사항). **로컬 터미널**에서 실행합니다(Web Terminal 불가).

| 스크립트 | 내용 |
|---|---|
| `create_workshop_users.sh` | htpasswd 사용자(`user01`..`userN`) 생성, cluster-admin RBAC 및 `rhods-admins` 그룹 멤버십 부여. `--num-users=<N>` 옵션 지원 (기본값: 20). |
| `gpu_machineset_hardwareprofiles.sh` | GPU MachineSet(`g6.2xlarge`, replicas=0) 생성 및 `gpu-profile` HardwareProfile에 nodeSelector + toleration 패치. Kueue 불필요. |

자세한 내용은 [`scripts/workshop-prep/README.md`](scripts/workshop-prep/README.md)를 참조하세요.

모든 스크립트는 **멱등(idempotent)** 합니다 -- 중단되거나 오퍼레이터가 백그라운드에서 설치 중이더라도 안전하게 재실행할 수 있습니다.

---

## 실행 단계

### 1단계: 환경 주문

[Red Hat Demo Platform (RHDP)](https://demo.redhat.com)에서 **Red Hat OpenShift AI 3**을 주문합니다. 환경이 완전히 프로비저닝되고 모든 노드가 준비될 때까지 기다립니다.

![Red Hat OpenShift AI 3 - RHDP Catalog](images/img-red-hat-openshift-ai-3.png)

### 2단계: 로그인

RHDP 주문 확인에 제공된 자격 증명을 사용합니다. OpenShift 콘솔에 로그인하고 클러스터에 접근할 수 있는지 확인합니다.

### 3단계: Web Terminal 설치

OpenShift 콘솔에서:

1. **Ecosystem** > **Software Catalog**로 이동
2. **Web Terminal** 검색

![Web Terminal Operator in Software Catalog](images/img-web-terminal-operator.png)

3. 기본 설정으로 설치

![Install Web Terminal](images/img-install-web-terminal.png)

4. 설치 완료 후 콘솔 우측 상단의 **>_** 아이콘을 클릭하여 터미널 세션 열기

![Open Web Terminal](images/img-initiate-cli.png)

Web Terminal에서 설정 스크립트를 실행합니다. `oc`가 이미 인증된 상태로 사전 구성되어 있습니다.

### 4단계: 모든 기능 활성화

Web Terminal(또는 `oc login`이 완료된 터미널)에서:

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-sno-setup-guide/main/scripts/sno-enable-all-features-35.sh | bash
```

또는 리포지토리를 클론하여 로컬에서 실행:

```bash
git clone https://github.com/jingggg-wenn/rhoai-sno-setup-guide.git
cd rhoai-sno-setup-guide
bash scripts/sno-enable-all-features-35.sh
```

> **참고:** Web Terminal에서 RHCL/Service Mesh 설치(6단계) 시 세션이 일시적으로 끊길 수 있습니다. 이 경우 OLM이 백그라운드에서 오퍼레이터 설치를 계속 진행합니다. 재접속 후 스크립트를 다시 실행하면 완료된 단계는 건너뜁니다.
>
> 중단 없이 실행하려면:
>
> ```bash
> nohup bash scripts/sno-enable-all-features-35.sh > /tmp/sno.log 2>&1 &
> tail -f /tmp/sno.log
> ```

> **실행 결과 예시:** [sno-all-features-output.txt](sample-output/sno-all-features-output.txt)

### 5단계: MaaS 설정

스크립트 1이 완료된 후 (모든 오퍼레이터 설치 및 검증 완료):

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-sno-setup-guide/main/scripts/sno-setup-maas-35.sh | bash
```

또는 리포지토리를 클론한 경우:

```bash
bash scripts/sno-setup-maas-35.sh
```

옵션:

```
--postgres-connection <url>   내장 POC 인스턴스 대신 외부 PostgreSQL 사용
--skip-rate-limiting          Redis 및 EnvoyFilter 설정 건너뛰기
```

> **실행 결과 예시:** [enable-maas-output.txt](sample-output/enable-maas-output.txt)

### 6단계: 모델 배포

두 스크립트가 모두 완료되면:

1. RHOAI Dashboard 열기 (각 스크립트 실행 후 URL이 출력됩니다)
2. **Gen AI Studio** > **Deploy**로 이동
3. 모델을 선택하고 MaaS 통합을 위해 **llm-d** 런타임으로 배포
4. Dashboard에서 Subscription 및 Auth Policy 등록

### 7단계: MaaS 엔드포인트 확인

```bash
TOKEN=$(oc whoami -t)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk https://maas.${CLUSTER_DOMAIN}/v1/models -H "Authorization: Bearer $TOKEN"
```

---

## 알려진 이슈 (RHOAI 3.5.1)

- **MaaS 게이트웨이를 통한 비스트리밍 chat/completions** 요청 시 빈 응답(0바이트)이 반환될 수 있습니다. 이는 `ext_proc` 필터의 `FULL_DUPLEX_STREAMED` 응답 본문 모드가 단일 본문(비스트리밍) 응답과 충돌하기 때문입니다. 스트리밍(`stream: true`)은 정상 작동합니다. Playground는 기본적으로 스트리밍을 사용하므로 영향을 받지 않습니다.

---

## 검증 명령어

두 스크립트 실행 후 클러스터 상태를 확인하려면:

```bash
# RHOAI 오퍼레이터 및 DSC 상태
oc get csv -n redhat-ods-operator
oc get datasciencecluster default-dsc

# 설치된 오퍼레이터
oc get csv -A | grep -E "nfd|gpu|kueue|lws|rhcl|rhods|cert-manager|tempo|opentelemetry|observability"

# MaaS 게이트웨이
oc get gateway -n openshift-ingress

# Dashboard URL
oc get route data-science-gateway -n redhat-ods-applications -o jsonpath='{.spec.host}'

# MaaS 테넌트
oc get tenant -n models-as-a-service

# Kuadrant 및 Authorino
oc get kuadrant -n kuadrant-system
oc get authorino -n kuadrant-system
```
