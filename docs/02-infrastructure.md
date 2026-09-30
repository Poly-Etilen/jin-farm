# JinFarm 인프라 · CI/CD

> 작성일: 2026-09-29 · 상태: 초안 (v0.1)

## 1. 결정 사항

| 항목 | 결정 | 이유 |
|---|---|---|
| 서버 위치 | **자체 서버** (집 또는 농장 건물) | 월 예산 무료~1만원 |
| 저장소 · CI/CD | **GitHub + GitHub Actions** | 무료, 자료 많음 |
| 실행 방식 | **Docker Compose** (앱 + PostgreSQL) | 서버 1대에서 단순하게 운영, 나중에 클라우드로 옮기기 쉬움 |
| 이미지 저장소 | **GHCR** (GitHub Container Registry) | GitHub 계정으로 바로 사용, 버전별 이미지 보관 → 롤백 가능 |
| 배포 방식 | 서버에 **self-hosted runner** 설치 | 공유기 포트포워딩 없이 서버가 GitHub에 먼저 접속해 배포 작업을 받아옴 |
| 도메인 | 없음 → **추후 구매** | 구매 시 Cloudflare Tunnel로 HTTPS 공개 (4장) |
| 코드 품질 | **SonarQube Community Build (로컬 Docker)** + JaCoCo 커버리지 | 무료, 익숙한 자체 설치형. 서버 준비 후 서버로 이전 검토 |

## 2. 전체 구성

```
 개발 PC ── git push ──▶ GitHub
  └─ (로컬) SonarQube :9000 ── 수동 분석
                           │
            ┌──────────────┴──────────────┐
            │ GitHub Actions (클라우드)     │
            │  PR  → CI: 빌드 + 테스트       │
            │  main → CD: 빌드 + 테스트       │
            │         → 이미지 빌드 (amd64/arm64)
            │         → GHCR에 push          │
            └──────────────┬──────────────┘
                           │ 배포 작업 (서버가 먼저 GitHub에 접속해서 받아감)
                           ▼
 ┌─────────────── 자체 서버 (집/농장 건물) ───────────────┐
 │  self-hosted runner ── docker compose pull / up        │
 │                                                        │
 │  [app: Spring Boot :8080] ── [db: PostgreSQL 17]        │
 │                                  └─ volume: db-data    │
 │  cron: backup.sh (매일 PostgreSQL 백업)                  │
 │  (도메인 구매 후) cloudflared ── HTTPS ── 인터넷          │
 └────────────────────────────────────────────────────────┘
```

## 3. 파이프라인

| 워크플로 | 트리거 | 하는 일 |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | main으로 가는 PR | Java 21로 빌드 + 테스트 + JaCoCo 커버리지, 커버리지 보고서를 Actions 결과물로 업로드 |
| [`cd.yml`](../.github/workflows/cd.yml) | main에 push, 수동 실행 | ① 빌드·테스트 ② 이미지를 `ghcr.io/<owner>/jinfarm:<커밋SHA>`, `:latest`로 push ③ 서버 runner가 새 이미지로 교체 ④ `/actuator/health` 확인, 실패 시 로그 출력 후 실패 처리 |

- 이미지는 **amd64와 arm64를 둘 다** 만든다. 서버가 미니PC든 라즈베리파이든 같은 파이프라인을 쓴다.
  jar는 CI에서 먼저 빌드하고 Dockerfile은 jar만 복사하므로 arm64 빌드도 빠르다.
- 배포(③④)는 저장소 변수 **`DEPLOY_ENABLED`가 `true`일 때만** 실행된다. 서버와 runner가 준비되기 전에는 건너뛴다(skipped).
  켜는 곳: 저장소 Settings → Secrets and variables → Actions → **Variables** 탭 → `DEPLOY_ENABLED` = `true`
- 배포는 한 번에 하나만 실행된다 (`concurrency`).
- `environment: production`을 쓰므로, GitHub 설정에서 **배포 전 승인**을 켤 수 있다.

### SonarQube (로컬 Docker)

| 항목 | 값 |
|---|---|
| 구성 | [`tools/sonarqube/docker-compose.yml`](../tools/sonarqube/docker-compose.yml) — SonarQube Community Build + PostgreSQL |
| 주소 | http://localhost:9000 (이 PC에서만 접속 가능) |
| Project key | `jinfarm` (`pom.xml`의 `sonar.*` 속성) |
| 인증 | 환경변수 `SONAR_TOKEN` (SonarQube에서 발급한 토큰) |
| 메모리 | SonarQube 컨테이너 최대 3GB. Docker Desktop에 4GB 이상 할당 권장 |

**처음 한 번**

1. `docker compose -f tools/sonarqube/docker-compose.yml up -d` → 1~2분 후 http://localhost:9000 접속
2. 초기 계정으로 로그인 후 **관리자 비밀번호 변경** (초기 계정은 SonarQube 공식 문서 참고)
3. 우측 상단 계정 → My Account → Security → **Generate Token** (종류: Global Analysis Token)
4. 토큰을 사용자 환경변수 `SONAR_TOKEN`으로 등록 (Windows: 시스템 속성 → 환경 변수), 터미널 재시작

**분석 실행** (코드 변경 후, PR 올리기 전)

```bash
./mvnw verify org.sonarsource.scanner.maven:sonar-maven-plugin:sonar
```

→ http://localhost:9000/dashboard?id=jinfarm 에서 결과 확인. 첫 분석 시 프로젝트가 자동 생성된다.

**한계와 이후 계획**

- Community Build는 **main 브랜치 분석만** 지원한다 (브랜치·PR 분석은 유료판).
- GitHub Actions의 클라우드 러너는 로컬 SonarQube에 접속할 수 없으므로 **CI에서는 분석하지 않는다.**
- 서버가 준비되면 SonarQube를 서버로 옮기고, 서버의 self-hosted runner에서 main 분석을 자동 실행하는 방안을 검토한다.
  단, 미니PC 기준 SonarQube가 메모리 2~3GB를 차지하므로 서버 사양(RAM 16GB 권장)을 함께 고려한다.
- 커버리지만 보려면 `mvnw verify` 후 `target/site/jacoco/index.html`을 연다.

### 관련 파일

| 파일 | 설명 |
|---|---|
| [`Dockerfile`](../Dockerfile) | JRE 21 런타임 이미지, 비root 사용자, `prod` 프로필, 서울 시간대 |
| [`deploy/docker-compose.yml`](../deploy/docker-compose.yml) | 앱 + PostgreSQL, 자동 재시작, 로그 크기 제한 |
| [`deploy/.env.example`](../deploy/.env.example) | 서버 환경변수 예시 (실제 값은 서버 `/opt/jinfarm/.env`에만) |
| [`deploy/backup.sh`](../deploy/backup.sh) | PostgreSQL 일일 백업, 14일 보관 |
| [`application-prod.properties`](../src/main/resources/application-prod.properties) | 운영 DB 접속 정보(환경변수), graceful shutdown |
| [`SecurityConfig.java`](../src/main/java/org/farm/jinfarm/config/SecurityConfig.java) | 헬스체크 공개 (카카오 로그인 도입 전 임시 설정) |

### 로컬 검증 결과 (2026-09-29)

- `mvnw verify` 통과
- Docker 이미지 빌드 → `docker compose`로 앱 + PostgreSQL 실행
  → `prod` 프로필로 PostgreSQL 연결, `/actuator/health` = `UP`, 그 외 경로는 로그인 페이지로 이동
- `pg_dump` 백업 명령 동작 확인

## 4. 외부 공개 (접속 경로)

| 시기 | 방법 | 비고 |
|---|---|---|
| **지금** | 같은 공유기 내부망에서 `http://<서버IP>:8080` | 외부에서 개발 확인이 필요하면 **Tailscale**(무료 개인 VPN)로 서버에 접속 |
| **도메인 구매 후** | **Cloudflare Tunnel** | 포트포워딩·고정 IP 없이 HTTPS 공개, 무료. 도메인 비용만 연 1~2만원 |

- 카카오 로그인은 개발 중에는 `localhost` 주소로 테스트할 수 있다. 실제 농가가 쓰려면 **HTTPS 도메인이 필요**하므로, 카카오 로그인 개발을 마칠 즈음 도메인을 산다.
- 공유기 포트포워딩으로 서버를 직접 열지 않는다 (공격 노출, 가정용 IP 변경 문제).

## 5. 서버 준비 절차

> 서버 하드웨어가 정해지면 진행한다. 아래는 **Ubuntu Server 24.04 LTS** 기준.

### 5.1 권장 사양

| 선택지 | 사양 | 장단점 |
|---|---|---|
| 미니PC (추천) | Intel N100급, RAM 8~16GB, SSD 256GB 이상 | 10만원대 후반~, 전력 낮음(6~15W), 성능 여유 |
| 라즈베리파이 5 | 8GB + NVMe SSD (SD카드는 DB용으로 비추천) | 저전력, 저렴. 성능 여유 적음 |
| 남는 PC/노트북 | RAM 8GB 이상 | 추가 비용 없음, 전력 소모 큼 |

### 5.2 설치 순서

1. **Ubuntu Server 설치**, 자동 보안 업데이트(`unattended-upgrades`) 켜기
2. **Docker 설치** (공식 문서의 `get.docker.com` 스크립트 또는 apt 저장소)
3. **배포 폴더 준비**
   ```bash
   sudo mkdir -p /opt/jinfarm/backups
   sudo chown -R $USER /opt/jinfarm
   cp deploy/.env.example /opt/jinfarm/.env   # 값 채우기, DB_PASSWORD는 긴 무작위 문자열
   chmod 600 /opt/jinfarm/.env
   cp deploy/backup.sh /opt/jinfarm/ && chmod +x /opt/jinfarm/backup.sh
   ```
4. **runner 전용 사용자** 만들고 docker 그룹에 추가
   ```bash
   sudo useradd -m -s /bin/bash gh-runner
   sudo usermod -aG docker gh-runner
   ```
5. **self-hosted runner 설치**: GitHub 저장소 → Settings → Actions → Runners → New self-hosted runner
   - 안내된 명령을 `gh-runner` 사용자로 실행
   - `config.sh` 실행 시 라벨에 **`jinfarm-prod`** 추가
   - `sudo ./svc.sh install gh-runner && sudo ./svc.sh start` 로 서비스 등록 (재부팅 시 자동 실행)
6. **배포 켜기**: GitHub 저장소 변수 `DEPLOY_ENABLED` = `true` 등록 (3장 참고)
7. **백업 cron 등록** (`crontab -e`)
   ```
   30 3 * * * /opt/jinfarm/backup.sh >> /opt/jinfarm/backup.log 2>&1
   ```
8. **정전 대비**: BIOS에서 "AC 전원 복구 시 자동 켜짐" 설정. 가능하면 소형 UPS

### 5.3 GitHub 저장소 설정

| 설정 | 값 | 이유 |
|---|---|---|
| 저장소 공개 범위 | **Private** | 공개 저장소에 self-hosted runner를 붙이면 외부인이 PR로 서버에서 코드를 실행할 수 있음 |
| Branch protection (main) | PR 필수, CI 통과 필수 | main = 운영 배포이므로 |
| Environments → production | (선택) Required reviewers | 배포 전 수동 승인 |
| GHCR 패키지 | 첫 배포 후 저장소와 연결 확인 | runner가 `GITHUB_TOKEN`으로 pull |

## 6. 운영

| 작업 | 방법 |
|---|---|
| 상태 확인 | `docker compose -p jinfarm ps`, `curl localhost:8080/actuator/health` |
| 로그 | `docker compose -p jinfarm logs -f app` |
| 롤백 | GitHub Actions에서 이전 성공 커밋의 CD를 **Re-run**, 또는 서버에서 `APP_TAG=<이전 SHA>`로 `up -d` |
| 백업 복원 | `gunzip -c <백업파일> \| docker compose -p jinfarm exec -T db psql -U jinfarm -d jinfarm` |
| 백업 외부 보관 | (추후) 백업 파일을 다른 디스크 또는 클라우드 저장소로 복사 — 서버 디스크 고장 대비 |

## 7. 비용

| 항목 | 비용 |
|---|---|
| GitHub (Private 저장소, Actions, GHCR) | 무료 한도 내 (Actions 월 2,000분, 패키지 저장 500MB) |
| SonarQube Community Build | 무료 (로컬 Docker) |
| 서버 전기료 | 미니PC 기준 월 1~2천원 수준 |
| 도메인 | 추후 연 1~2만원 |
| Cloudflare Tunnel, Tailscale | 무료 |

> GHCR 무료 저장 공간이 한도에 가까워지면 오래된 이미지 버전을 정리하는 작업을 추가한다.

## 8. 남은 결정 / 할 일

| # | 항목 | 상태 |
|---|---|---|
| I1 | 서버 하드웨어 (미니PC / 라즈베리파이 / 남는 PC) | 미정 |
| I2 | 서버 위치 (집 / 농장 건물) | 미정 |
| I3 | GitHub 저장소 생성 (Private) 및 첫 push | 미정 |
| I4 | 도메인 구매 + Cloudflare Tunnel | 카카오 로그인 개발 시점 |
| I5 | DB 스키마 관리 도구(Flyway) 도입 | 첫 엔티티 작성 시 |
| I6 | 백업 외부 보관 | 운영 시작 전 |
