#!/bin/sh
# 컨테이너 시작 시 서버 계정의 비밀번호 파일을 환경변수로 다시 만든다 (비밀번호는 이미지·저장소에 남기지 않음)
set -e

: "${MQTT_USERNAME:?MQTT_USERNAME is required}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD is required}"

passwd_file=/mosquitto/data/passwd
rm -f "$passwd_file"
mosquitto_passwd -c -b "$passwd_file" "$MQTT_USERNAME" "$MQTT_PASSWORD"
chown mosquitto:mosquitto "$passwd_file"
chmod 0700 "$passwd_file"

exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf
