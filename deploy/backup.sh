#!/usr/bin/env bash
# PostgreSQL 일일 백업. 서버 crontab 예시:
#   30 3 * * * /opt/jinfarm/backup.sh >> /opt/jinfarm/backup.log 2>&1
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/jinfarm/backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
ENV_FILE="${ENV_FILE:-/opt/jinfarm/.env}"

set -a; source "$ENV_FILE"; set +a
mkdir -p "$BACKUP_DIR"

file="$BACKUP_DIR/jinfarm-$(date +%Y%m%d-%H%M%S).sql.gz"
docker compose -p jinfarm exec -T db pg_dump -U "$DB_USER" -d "${DB_NAME:-jinfarm}" | gzip > "$file"
echo "$(date '+%F %T') backup created: $file"

find "$BACKUP_DIR" -name 'jinfarm-*.sql.gz' -mtime +"$KEEP_DAYS" -delete
