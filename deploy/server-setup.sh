#!/usr/bin/env bash
# JinFarm 서버 초기 설정 (Ubuntu). 여러 번 실행해도 안전하다.
#   sudo bash deploy/server-setup.sh
# 하는 일: Docker 설치, runner 전용 사용자(gh-runner), /opt/jinfarm 준비(.env 생성), 백업 cron 등록
set -euo pipefail

RUNNER_USER=gh-runner
APP_DIR=/opt/jinfarm
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "sudo로 실행하세요: sudo bash $0" >&2
  exit 1
fi

echo "==> 1. 패키지 설치 (Docker, Compose, curl)"
apt-get update -y
apt-get install -y docker.io docker-compose-v2 curl openssl ca-certificates cron
systemctl enable --now docker
systemctl enable --now cron

echo "==> 2. runner 전용 사용자: $RUNNER_USER"
if ! id "$RUNNER_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

echo "==> 3. 배포 폴더: $APP_DIR"
mkdir -p "$APP_DIR/backups"
install -m 755 "$SCRIPT_DIR/backup.sh" "$APP_DIR/backup.sh"

if [[ ! -f "$APP_DIR/.env" ]]; then
  sed "s/^DB_PASSWORD=.*/DB_PASSWORD=$(openssl rand -hex 24)/" "$SCRIPT_DIR/.env.example" > "$APP_DIR/.env"
  echo "    .env 생성 (DB 비밀번호 무작위 생성)"
else
  echo "    .env 이미 있음 — 유지"
fi
chown -R "$RUNNER_USER:$RUNNER_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env"

echo "==> 4. 백업 cron (매일 03:30, $RUNNER_USER)"
CRON_LINE="30 3 * * * $APP_DIR/backup.sh >> $APP_DIR/backup.log 2>&1"
( crontab -u "$RUNNER_USER" -l 2>/dev/null | grep -vF "$APP_DIR/backup.sh" || true; echo "$CRON_LINE" ) \
  | crontab -u "$RUNNER_USER" -

echo "==> 5. 확인"
sudo -u "$RUNNER_USER" docker version --format '    docker server {{.Server.Version}}'
sudo -u "$RUNNER_USER" docker compose version | sed 's/^/    /'

cat <<EOF

완료. 다음 단계: GitHub Actions runner 설치 (docs/02-infrastructure.md 5.2 참고)
  sudo -iu $RUNNER_USER
  mkdir actions-runner && cd actions-runner
  # GitHub 저장소 → Settings → Actions → Runners → New self-hosted runner (Linux x64) 의
  # Download / Configure 명령 실행. config.sh 실행 시 라벨에 jinfarm-prod 추가
  exit
  cd /home/$RUNNER_USER/actions-runner && sudo ./svc.sh install $RUNNER_USER && sudo ./svc.sh start
EOF
