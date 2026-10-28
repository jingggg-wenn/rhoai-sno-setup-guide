# 워크숍 환경 설정

작성일: 28 Oct 2026

워크숍 참가자를 위한 간략한 설정 가이드입니다. 워크숍 시작 전 아래 단계를 따라 클러스터 환경을 준비합니다.

---

## 1단계: 로그인

워크숍 강사가 제공한 자격 증명을 사용합니다. OpenShift 콘솔에 로그인하고 클러스터에 접근할 수 있는지 확인합니다.

## 2단계: Web Terminal 설치

OpenShift 콘솔에서:

1. **Ecosystem** > **Software Catalog**로 이동
2. **Web Terminal** 검색

![Web Terminal Operator - Software Catalog](../images/img-web-terminal-operator.png)

3. 기본 설정으로 설치

![Web Terminal 설치](../images/img-install-web-terminal.png)

4. 설치 완료 후 콘솔 우측 상단의 **>_** 아이콘을 클릭하여 터미널 세션 열기

![Web Terminal 열기](../images/img-initiate-cli.png)

Web Terminal은 `oc`가 이미 인증된 상태로 사전 구성되어 있습니다. 아래 모든 명령어는 이 터미널에서 실행합니다.

## 3단계: 모든 기능 활성화

Web Terminal에서 다음 명령어를 실행합니다:

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-sno-setup-guide/main/scripts/sno-enable-all-features-35.sh | bash
```

이 스크립트는 RHOAI 3.5의 모든 컴포넌트를 활성화하고, 필수 오퍼레이터를 설치하며, 대시보드를 구성합니다. 완료까지 수 분이 소요됩니다. 변경 사항의 전체 목록은 [구성 내용](../README_KR.md#구성-내용)을 참고하세요.

> **참고:** RHCL/Service Mesh 설치 시 Web Terminal 세션이 일시적으로 끊길 수 있습니다. 이 경우 오퍼레이터는 백그라운드에서 계속 설치됩니다. 재접속 후 동일한 명령어를 다시 실행하면 완료된 단계는 자동으로 건너뜁니다.

## 4단계: MaaS 설정

3단계 완료 후 다음을 실행합니다:

```bash
curl -sL https://raw.githubusercontent.com/jingggg-wenn/rhoai-sno-setup-guide/main/scripts/sno-setup-maas-35.sh | bash
```

Models-as-a-Service 인프라(데이터베이스, 인증, Rate Limiting, 게이트웨이)를 구성합니다. 자세한 내용은 [구성 내용](../README_KR.md#구성-내용)을 참고하세요.

## 완료

두 스크립트가 모두 완료되면 환경이 준비됩니다. RHOAI Dashboard URL은 각 스크립트 실행 후 출력됩니다.

> **참고:** 클러스터에는 `my-first-model`이 이미 배포되어 있으며 단일 GPU를 점유하고 있습니다. 새 모델을 배포하려면 먼저 이 모델을 중지해야 합니다. **Gen AI Studio** > **Models**에서 `my-first-model`을 삭제하거나 스케일 다운하세요.
