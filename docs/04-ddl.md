# JinFarm DDL (PostgreSQL)

> 작성일: 2026-09-30 · 상태: 초안 (v0.3 — `alerts.simulated` 추가, Redis 기상 실황 키 추가)
> 기준 문서: [04-domain-model.md](04-domain-model.md) v0.2 · 대상: **PostgreSQL 17**
> 이 문서의 SQL은 구현 시 Flyway 마이그레이션 `V1__init.sql`로 옮긴다.

## 1. 규칙

| 항목 | 규칙 |
|---|---|
| 식별자 | `BIGINT GENERATED ALWAYS AS IDENTITY` |
| 시각 | `TIMESTAMPTZ` (UTC 저장). `created_at`은 DB 기본값 `now()`, `updated_at`은 JPA(`@UpdateTimestamp`)가 갱신 |
| 코드 값 | `VARCHAR` + 애플리케이션 `enum`. 값 목록 CHECK는 두지 않는다 (값 추가 시 마이그레이션 불필요). 상태 간 **정합성** CHECK만 둔다 |
| 논리 삭제 | `deleted_at`. 이름 중복 검사는 **삭제되지 않은 행만** 대상으로 하는 부분 UNIQUE 인덱스로 한다 |
| **농장 격리 (DB 수준)** | 하위 테이블은 `(farm_id, 상위_id)` **복합 외래키**로 상위 테이블을 참조한다 → 다른 농장의 밭·구역·작물을 가리키는 행은 DB가 거부한다 |
| 이름 | 테이블·컬럼은 snake_case 복수형 테이블명, 제약 이름은 `pk_`, `uk_`, `fk_`, `ck_`, `ix_` 접두사 |

### 1.1 복합 외래키로 농장 격리

```
fields  (farm_id, id)          ◀── zones   (farm_id, field_id)
zones   (farm_id, field_id, id)◀── devices (farm_id, field_id, zone_id)
zones   (farm_id, id)          ◀── plantings (farm_id, zone_id)
crops   (farm_id, id)          ◀── plantings (farm_id, crop_id)
devices (farm_id, id)          ◀── devices (farm_id, gateway_id)
```

- 상위 테이블에 `UNIQUE (farm_id, id)`를 두고 하위 테이블이 이를 참조한다.
- `devices`는 `(farm_id, field_id, zone_id)`로 구역을 참조해 **구역이 그 밭에 속하는지**까지 보장한다.
- 외래키 컬럼 중 하나라도 NULL이면 검사하지 않는다 (PostgreSQL 기본 `MATCH SIMPLE`) → 밭 공용·농장 공용 장치 허용.

## 2. 테이블 목록

| # | 테이블 | 설명 | 삭제 방식 |
|---|---|---|---|
| 1 | `forecast_grids` | 기상청 예보 격자 | 물리 |
| 2 | `users` | 사용자 (아이디/비밀번호는 선택) | 논리 |
| 3 | `user_identities` | 소셜 로그인 계정 연결 (카카오 등) | 물리 (연결 해제·탈퇴 시) |
| 4 | `farms` | 농장 | 논리 |
| 5 | `farm_members` | 사용자 ↔ 농장 + 역할 | 물리 |
| 6 | `fields` | 밭 | 논리 |
| 7 | `zones` | 구역 | 논리 |
| 8 | `devices` | 장치 | 논리 |
| 9 | `crops` | 작물 프로필 | 논리 |
| 10 | `plantings` | 재배 기록 | 보관 (종료 처리) |
| 11 | `weather_forecasts` | 격자별 예보값 | 물리 (7일 지난 값 삭제) |
| 12 | `alerts` | 알림 (이상 상황) | 물리 (보관 기간 후) |
| 13 | `notifications` | 알림 발송 내역 | 물리 (알림 삭제 시 함께) |
| 14 | `chat_conversations` | AI 챗봇 대화방 (P1) | 논리 → 90일 후 물리 |
| 15 | `chat_messages` | AI 챗봇 대화 내용 (P1) | 물리 (대화방 삭제 시 함께) |

> 14~15는 AI 챗봇([06-ai-chatbot.md](06-ai-chatbot.md), P1) 구현 시 별도 마이그레이션(`V2__chat.sql`)으로 추가한다.

센서 측정값은 PostgreSQL이 아니라 InfluxDB에 저장한다 (5장).

## 3. DDL

### 3.1 기상 예보 격자

```sql
CREATE TABLE forecast_grids (
    id               BIGINT GENERATED ALWAYS AS IDENTITY,
    nx               INTEGER     NOT NULL,
    ny               INTEGER     NOT NULL,
    last_fetched_at  TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_forecast_grids PRIMARY KEY (id),
    CONSTRAINT uk_forecast_grids_nx_ny UNIQUE (nx, ny)
);

COMMENT ON TABLE  forecast_grids IS '기상청 단기예보 격자. 가까운 농장끼리 같은 격자를 공유';
COMMENT ON COLUMN forecast_grids.nx IS '기상청 격자 X';
COMMENT ON COLUMN forecast_grids.ny IS '기상청 격자 Y';
```

### 3.2 사용자

```sql
CREATE TABLE users (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY,
    login_id             VARCHAR(20),
    password_hash        VARCHAR(100),
    nickname             VARCHAR(50)  NOT NULL,
    email                VARCHAR(255),
    profile_image_url    VARCHAR(500),
    password_changed_at  TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at           TIMESTAMPTZ,

    CONSTRAINT pk_users PRIMARY KEY (id),
    CONSTRAINT ck_users_login_pair CHECK ((login_id IS NULL) = (password_hash IS NULL)),
    CONSTRAINT ck_users_login_id_format CHECK (login_id ~ '^[a-z][a-z0-9_]{3,19}$')
);

-- 탈퇴한 사용자의 아이디를 다시 쓸 수 있도록 삭제되지 않은 행만 중복 검사
CREATE UNIQUE INDEX uk_users_login_id ON users (login_id) WHERE deleted_at IS NULL;

COMMENT ON TABLE  users IS '사용자. 로그인 수단은 아이디/비밀번호(이 테이블) 또는 소셜 계정(user_identities). 탈퇴 시 deleted_at 기록 후 개인정보·로그인 정보를 비운다';
COMMENT ON COLUMN users.login_id IS '아이디 (소문자로 저장). 소셜 전용 사용자는 NULL';
COMMENT ON COLUMN users.password_hash IS 'BCrypt 해시 ({bcrypt} 접두사 포함). 아이디와 함께 있거나 함께 없음';
```

### 3.3 소셜 계정 연결

```sql
CREATE TABLE user_identities (
    id                BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id           BIGINT       NOT NULL,
    provider          VARCHAR(20)  NOT NULL,
    provider_user_id  VARCHAR(64)  NOT NULL,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT pk_user_identities PRIMARY KEY (id),
    CONSTRAINT uk_user_identities_provider_user UNIQUE (provider, provider_user_id),
    CONSTRAINT uk_user_identities_user_provider UNIQUE (user_id, provider),
    CONSTRAINT fk_user_identities_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

COMMENT ON TABLE  user_identities IS '소셜 로그인 계정. 사용자당 제공자별 1개. 카카오 토큰은 여기가 아니라 Redis(kakao:token:{userId})에 저장';
COMMENT ON COLUMN user_identities.provider IS 'KAKAO (이후 GOOGLE, NAVER)';
COMMENT ON COLUMN user_identities.provider_user_id IS '제공자의 회원번호 (카카오 회원번호)';
```

### 3.4 농장

```sql
CREATE TABLE farms (
    id                BIGINT GENERATED ALWAYS AS IDENTITY,
    name              VARCHAR(100)  NOT NULL,
    address           VARCHAR(255),
    latitude          NUMERIC(9, 6),
    longitude         NUMERIC(9, 6),
    forecast_grid_id  BIGINT,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ,

    CONSTRAINT pk_farms PRIMARY KEY (id),
    CONSTRAINT fk_farms_forecast_grid FOREIGN KEY (forecast_grid_id) REFERENCES forecast_grids (id),
    CONSTRAINT ck_farms_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_farms_longitude CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT ck_farms_location_pair CHECK ((latitude IS NULL) = (longitude IS NULL))
);

CREATE INDEX ix_farms_forecast_grid ON farms (forecast_grid_id) WHERE deleted_at IS NULL;

COMMENT ON TABLE  farms IS '농장. 위경도로 기상청 격자를 계산해 forecast_grid_id 연결';
```

### 3.5 농장 멤버

```sql
CREATE TABLE farm_members (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id     BIGINT       NOT NULL,
    user_id     BIGINT       NOT NULL,
    role        VARCHAR(20)  NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT pk_farm_members PRIMARY KEY (id),
    CONSTRAINT uk_farm_members_farm_user UNIQUE (farm_id, user_id),
    CONSTRAINT fk_farm_members_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT fk_farm_members_user FOREIGN KEY (user_id) REFERENCES users (id)
);

-- 로그인 사용자의 농장 목록 조회
CREATE INDEX ix_farm_members_user ON farm_members (user_id);

COMMENT ON COLUMN farm_members.role IS 'OWNER / WORKER / VIEWER. 농장마다 OWNER 최소 1명은 애플리케이션에서 보장';
```

### 3.6 밭

```sql
CREATE TABLE fields (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id     BIGINT         NOT NULL,
    name        VARCHAR(50)    NOT NULL,
    area_m2     NUMERIC(10, 2),
    lot_number  VARCHAR(100),
    sort_order  INTEGER        NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT pk_fields PRIMARY KEY (id),
    CONSTRAINT uk_fields_farm_id UNIQUE (farm_id, id),
    CONSTRAINT fk_fields_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT ck_fields_area CHECK (area_m2 > 0)
);

CREATE UNIQUE INDEX uk_fields_farm_name ON fields (farm_id, name) WHERE deleted_at IS NULL;

COMMENT ON TABLE  fields IS '물리적으로 떨어진 밭(필지)';
COMMENT ON COLUMN fields.lot_number IS '지번';
```

### 3.7 구역

```sql
CREATE TABLE zones (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id     BIGINT         NOT NULL,
    field_id    BIGINT         NOT NULL,
    name        VARCHAR(50)    NOT NULL,
    area_m2     NUMERIC(10, 2),
    sort_order  INTEGER        NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT pk_zones PRIMARY KEY (id),
    CONSTRAINT uk_zones_farm_id UNIQUE (farm_id, id),
    CONSTRAINT uk_zones_farm_field_id UNIQUE (farm_id, field_id, id),
    CONSTRAINT fk_zones_field FOREIGN KEY (farm_id, field_id) REFERENCES fields (farm_id, id),
    CONSTRAINT ck_zones_area CHECK (area_m2 > 0)
);

CREATE UNIQUE INDEX uk_zones_field_name ON zones (field_id, name) WHERE deleted_at IS NULL;

COMMENT ON TABLE zones IS '같은 조건(관수 라인 등)을 공유하는 재배 단위';
```

### 3.8 장치

```sql
CREATE TABLE devices (
    id            BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id       BIGINT        NOT NULL,
    field_id      BIGINT,
    zone_id       BIGINT,
    gateway_id    BIGINT,
    type          VARCHAR(30)   NOT NULL,
    name          VARCHAR(50)   NOT NULL,
    key_prefix    CHAR(8)       NOT NULL,
    key_hash      VARCHAR(100)  NOT NULL,
    simulated     BOOLEAN       NOT NULL DEFAULT FALSE,
    last_seen_at  TIMESTAMPTZ,
    battery_pct   SMALLINT,
    rssi          SMALLINT,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,

    CONSTRAINT pk_devices PRIMARY KEY (id),
    CONSTRAINT uk_devices_farm_id UNIQUE (farm_id, id),
    CONSTRAINT uk_devices_key_prefix UNIQUE (key_prefix),
    CONSTRAINT fk_devices_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT fk_devices_field FOREIGN KEY (farm_id, field_id) REFERENCES fields (farm_id, id),
    CONSTRAINT fk_devices_zone FOREIGN KEY (farm_id, field_id, zone_id) REFERENCES zones (farm_id, field_id, id),
    CONSTRAINT fk_devices_gateway FOREIGN KEY (farm_id, gateway_id) REFERENCES devices (farm_id, id),
    CONSTRAINT ck_devices_zone_needs_field CHECK (zone_id IS NULL OR field_id IS NOT NULL),
    CONSTRAINT ck_devices_gateway_not_self CHECK (gateway_id IS NULL OR gateway_id <> id),
    CONSTRAINT ck_devices_battery CHECK (battery_pct BETWEEN 0 AND 100)
);

CREATE INDEX ix_devices_zone ON devices (farm_id, zone_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uk_devices_farm_name ON devices (farm_id, name) WHERE deleted_at IS NULL;

COMMENT ON TABLE  devices IS '게이트웨이, 토양 센서 노드, 기상 관측 장치. 설치 범위: 구역(field+zone) / 밭 공용(field) / 농장 공용(둘 다 NULL)';
COMMENT ON COLUMN devices.type IS 'GATEWAY / SOIL_SENSOR / WEATHER_STATION (2단계: VALVE / PUMP)';
COMMENT ON COLUMN devices.key_prefix IS '장치 키 앞 8자리 (조회용)';
COMMENT ON COLUMN devices.key_hash IS '장치 키 전체의 해시. 원문은 저장하지 않음';
COMMENT ON COLUMN devices.simulated IS '시뮬레이터 장치. 운영 환경에서는 수신 거부';
COMMENT ON COLUMN devices.last_seen_at IS 'Redis의 최신 상태를 주기적으로 반영';
```

### 3.9 작물 프로필

```sql
CREATE TABLE crops (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id            BIGINT        NOT NULL,
    name               VARCHAR(50)   NOT NULL,
    variety            VARCHAR(50),
    category           VARCHAR(20)   NOT NULL,
    lifecycle          VARCHAR(20)   NOT NULL,
    soil_moisture_min  NUMERIC(5, 2),
    soil_moisture_max  NUMERIC(5, 2),
    temp_low_limit     NUMERIC(4, 1),
    temp_high_limit    NUMERIC(4, 1),
    memo               TEXT,
    image_url          VARCHAR(500),
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at         TIMESTAMPTZ,

    CONSTRAINT pk_crops PRIMARY KEY (id),
    CONSTRAINT uk_crops_farm_id UNIQUE (farm_id, id),
    CONSTRAINT fk_crops_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT ck_crops_soil_moisture_range CHECK (
        (soil_moisture_min IS NULL OR soil_moisture_min BETWEEN 0 AND 100) AND
        (soil_moisture_max IS NULL OR soil_moisture_max BETWEEN 0 AND 100) AND
        (soil_moisture_min IS NULL OR soil_moisture_max IS NULL OR soil_moisture_min <= soil_moisture_max)
    ),
    CONSTRAINT ck_crops_temp_range CHECK (
        temp_low_limit IS NULL OR temp_high_limit IS NULL OR temp_low_limit < temp_high_limit
    )
);

-- 품종이 없는 작물끼리도 이름 중복을 막기 위해 COALESCE 사용
CREATE UNIQUE INDEX uk_crops_farm_name_variety ON crops (farm_id, name, COALESCE(variety, '')) WHERE deleted_at IS NULL;

COMMENT ON TABLE  crops IS '농장이 직접 등록한 작물 프로필. 기준값은 입력한 것만 알림에 사용';
COMMENT ON COLUMN crops.category IS 'FRUIT_TREE / VEGETABLE / ...';
COMMENT ON COLUMN crops.lifecycle IS 'ANNUAL(일년생) / PERENNIAL(다년생)';
COMMENT ON COLUMN crops.soil_moisture_min IS '적정 토양수분 하한 (%). 이하이면 건조 알림';
COMMENT ON COLUMN crops.temp_low_limit IS '저온 한계 (°C). 예보 최저기온이 이하이면 서리 알림';
```

### 3.10 재배

```sql
CREATE TABLE plantings (
    id             BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id        BIGINT       NOT NULL,
    zone_id        BIGINT       NOT NULL,
    crop_id        BIGINT       NOT NULL,
    planted_on     DATE         NOT NULL,
    quantity       INTEGER,
    quantity_unit  VARCHAR(10),
    status         VARCHAR(10)  NOT NULL DEFAULT 'ACTIVE',
    ended_on       DATE,
    end_reason     VARCHAR(20),
    memo           TEXT,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT pk_plantings PRIMARY KEY (id),
    CONSTRAINT fk_plantings_zone FOREIGN KEY (farm_id, zone_id) REFERENCES zones (farm_id, id),
    CONSTRAINT fk_plantings_crop FOREIGN KEY (farm_id, crop_id) REFERENCES crops (farm_id, id),
    CONSTRAINT ck_plantings_quantity CHECK (quantity > 0),
    CONSTRAINT ck_plantings_status CHECK (
        (status = 'ACTIVE' AND ended_on IS NULL     AND end_reason IS NULL) OR
        (status = 'ENDED'  AND ended_on IS NOT NULL AND end_reason IS NOT NULL)
    ),
    CONSTRAINT ck_plantings_dates CHECK (ended_on IS NULL OR ended_on >= planted_on)
);

-- 구역별 현재 재배 중인 작물 (대시보드, 알림 판단)
CREATE INDEX ix_plantings_active ON plantings (farm_id, zone_id) WHERE status = 'ACTIVE';
-- 구역별 재배 이력 (연작 이력)
CREATE INDEX ix_plantings_zone_history ON plantings (zone_id, planted_on DESC);
CREATE INDEX ix_plantings_crop ON plantings (crop_id);

COMMENT ON TABLE  plantings IS '구역에 작물을 심은 기록. 종료해도 삭제하지 않음. 한 구역에 ACTIVE 여러 개 허용(혼작)';
COMMENT ON COLUMN plantings.quantity_unit IS 'PLANT(포기) / TREE(그루)';
COMMENT ON COLUMN plantings.end_reason IS 'HARVESTED / DISCARDED / DIED';
```

### 3.11 기상 예보값

```sql
CREATE TABLE weather_forecasts (
    grid_id      BIGINT       NOT NULL,
    forecast_at  TIMESTAMPTZ  NOT NULL,
    category     VARCHAR(10)  NOT NULL,
    base_at      TIMESTAMPTZ  NOT NULL,
    value        VARCHAR(20)  NOT NULL,
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),

    CONSTRAINT pk_weather_forecasts PRIMARY KEY (grid_id, forecast_at, category),
    CONSTRAINT fk_weather_forecasts_grid FOREIGN KEY (grid_id) REFERENCES forecast_grids (id) ON DELETE CASCADE
);

-- 오래된 예보 정리
CREATE INDEX ix_weather_forecasts_forecast_at ON weather_forecasts (forecast_at);

COMMENT ON TABLE  weather_forecasts IS '격자별 예보값. 같은 키는 최신 발표로 덮어씀 (INSERT ... ON CONFLICT DO UPDATE)';
COMMENT ON COLUMN weather_forecasts.category IS '기상청 코드: TMP, TMN, TMX, POP, PCP, WSD ...';
COMMENT ON COLUMN weather_forecasts.base_at IS '예보 발표 시각';
COMMENT ON COLUMN weather_forecasts.value IS '"강수없음" 같은 문자열이 있어 문자열로 저장';
```

### 3.12 알림

```sql
CREATE TABLE alerts (
    id           BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id      BIGINT        NOT NULL,
    type         VARCHAR(30)   NOT NULL,
    severity     VARCHAR(10)   NOT NULL,
    target_type  VARCHAR(10)   NOT NULL,
    target_id    BIGINT,
    dedup_key    VARCHAR(200)  NOT NULL,
    status       VARCHAR(10)   NOT NULL DEFAULT 'OPEN',
    simulated    BOOLEAN       NOT NULL DEFAULT FALSE,
    message      TEXT          NOT NULL,
    detail       JSONB,
    opened_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    resolved_at  TIMESTAMPTZ,

    CONSTRAINT pk_alerts PRIMARY KEY (id),
    CONSTRAINT fk_alerts_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT ck_alerts_status CHECK (
        (status = 'OPEN'     AND resolved_at IS NULL) OR
        (status = 'RESOLVED' AND resolved_at IS NOT NULL AND resolved_at >= opened_at)
    )
);

-- 중복 억제 (ALM-07): 같은 원인의 열린 알림은 농장마다 하나만
CREATE UNIQUE INDEX uk_alerts_open_dedup ON alerts (farm_id, dedup_key) WHERE status = 'OPEN';
-- 농장 알림 목록 (최신순)
CREATE INDEX ix_alerts_farm_opened ON alerts (farm_id, opened_at DESC);

COMMENT ON TABLE  alerts IS '이상 상황 하나당 1행. OPEN → RESOLVED';
COMMENT ON COLUMN alerts.type IS 'SOIL_DRY / SOIL_WET / DEVICE_OFFLINE / BATTERY_LOW / FROST / HEAT / HEAVY_RAIN / STRONG_WIND';
COMMENT ON COLUMN alerts.target_type IS 'ZONE / DEVICE / FARM. target_id는 해당 테이블 id (FARM이면 NULL)';
COMMENT ON COLUMN alerts.dedup_key IS '알림 종류 + 대상. 예: SOIL_DRY:ZONE:12, FROST:FARM:2026-10-15';
COMMENT ON COLUMN alerts.detail IS '판단 당시 값 (측정값, 기준값, 예보값 등)';
COMMENT ON COLUMN alerts.simulated IS '시뮬레이터 장치 값이 근거인 알림 (화면 표시, 카카오톡 [시뮬레이터] 접두사). 예보 기반 알림은 항상 FALSE';
```

### 3.13 알림 발송

```sql
CREATE TABLE notifications (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id     BIGINT        NOT NULL,
    alert_id    BIGINT        NOT NULL,
    user_id     BIGINT        NOT NULL,
    event       VARCHAR(10)   NOT NULL,
    channel     VARCHAR(10)   NOT NULL,
    status      VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    attempts    SMALLINT      NOT NULL DEFAULT 0,
    last_error  VARCHAR(500),
    sent_at     TIMESTAMPTZ,
    read_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT pk_notifications PRIMARY KEY (id),
    CONSTRAINT uk_notifications_once UNIQUE (alert_id, user_id, event, channel),
    CONSTRAINT fk_notifications_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT fk_notifications_alert FOREIGN KEY (alert_id) REFERENCES alerts (id) ON DELETE CASCADE,
    CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES users (id),
    CONSTRAINT ck_notifications_attempts CHECK (attempts >= 0),
    CONSTRAINT ck_notifications_read_web_only CHECK (read_at IS NULL OR channel = 'WEB')
);

-- 발송 작업이 처리할 대기 건
CREATE INDEX ix_notifications_pending ON notifications (created_at) WHERE status = 'PENDING';
-- 사용자 웹 알림 목록 · 안 읽은 알림 수
CREATE INDEX ix_notifications_user_web ON notifications (user_id, farm_id, created_at DESC) WHERE channel = 'WEB';

COMMENT ON TABLE  notifications IS '알림을 누구에게 어떤 채널로 보냈는지. 멤버 × 채널 × 이벤트당 1행';
COMMENT ON COLUMN notifications.event IS 'OPENED(발생) / RESOLVED(정상 복귀)';
COMMENT ON COLUMN notifications.channel IS 'WEB / KAKAO';
COMMENT ON COLUMN notifications.status IS 'PENDING / SENT / FAILED';
COMMENT ON COLUMN notifications.read_at IS '웹 알림 읽음 시각 (ALM-04)';
```

### 3.14 AI 챗봇 대화방 (P1)

```sql
CREATE TABLE chat_conversations (
    id          BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id     BIGINT        NOT NULL,
    user_id     BIGINT        NOT NULL,
    title       VARCHAR(100),
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT pk_chat_conversations PRIMARY KEY (id),
    CONSTRAINT uk_chat_conversations_farm_id UNIQUE (farm_id, id),
    CONSTRAINT fk_chat_conversations_farm FOREIGN KEY (farm_id) REFERENCES farms (id),
    CONSTRAINT fk_chat_conversations_user FOREIGN KEY (user_id) REFERENCES users (id)
);

-- 내 대화방 목록 (최근 대화순)
CREATE INDEX ix_chat_conversations_user ON chat_conversations (farm_id, user_id, updated_at DESC) WHERE deleted_at IS NULL;

COMMENT ON TABLE  chat_conversations IS 'AI 챗봇 대화방. 본인만 조회 (같은 농장 멤버에게도 비공개)';
COMMENT ON COLUMN chat_conversations.title IS '첫 질문 앞부분으로 자동 생성';
```

### 3.15 AI 챗봇 메시지 (P1)

```sql
CREATE TABLE chat_messages (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY,
    farm_id              BIGINT        NOT NULL,
    conversation_id      BIGINT        NOT NULL,
    seq                  INTEGER       NOT NULL,
    role                 VARCHAR(10)   NOT NULL,
    content              JSONB         NOT NULL,
    model                VARCHAR(50),
    finish_reason        VARCHAR(30),
    input_tokens         INTEGER,
    output_tokens        INTEGER,
    thinking_tokens      INTEGER,
    cached_tokens        INTEGER,
    created_at           TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT pk_chat_messages PRIMARY KEY (id),
    CONSTRAINT uk_chat_messages_seq UNIQUE (conversation_id, seq),
    CONSTRAINT fk_chat_messages_conversation FOREIGN KEY (farm_id, conversation_id)
        REFERENCES chat_conversations (farm_id, id) ON DELETE CASCADE,
    CONSTRAINT ck_chat_messages_role CHECK (role IN ('user', 'model')),
    CONSTRAINT ck_chat_messages_seq CHECK (seq > 0),
    CONSTRAINT ck_chat_messages_usage CHECK (
        role = 'user' OR (input_tokens IS NOT NULL AND output_tokens IS NOT NULL)
    )
);

-- 월별 사용량 집계
CREATE INDEX ix_chat_messages_created ON chat_messages (created_at) WHERE role = 'model';

COMMENT ON TABLE  chat_messages IS 'Gemini contents 배열을 순서대로 저장. 수정하지 않고 뒤에만 추가 (append-only, 사고 서명 보존)';
COMMENT ON COLUMN chat_messages.role IS 'user(질문·함수 결과) / model(Gemini 응답). API 역할 값 그대로라 CHECK로 고정';
COMMENT ON COLUMN chat_messages.content IS 'Gemini Content JSON 원본 (텍스트·함수 호출·함수 결과·사고 서명 포함). 다음 요청에 그대로 재사용';
COMMENT ON COLUMN chat_messages.model IS '응답한 모델 id (예: gemini-3.6-flash). 모델 교체 후 비용 비교용';
COMMENT ON COLUMN chat_messages.input_tokens IS 'model 행: 이 응답의 입력 토큰 (비용 집계용)';
COMMENT ON COLUMN chat_messages.output_tokens IS 'model 행: 답변 출력 토큰 (사고 토큰 제외)';
COMMENT ON COLUMN chat_messages.thinking_tokens IS 'model 행: 사고 토큰. 출력 요금으로 과금';
COMMENT ON COLUMN chat_messages.cached_tokens IS 'model 행: 암묵적 캐시로 할인된 입력 토큰';
```

## 4. 주요 쿼리와 인덱스

| 용도 | 쿼리 조건 | 사용하는 인덱스 |
|---|---|---|
| 아이디 로그인 | `users.login_id = ?` (삭제 안 된 사용자) | `uk_users_login_id` |
| 카카오 로그인 | `user_identities (provider, provider_user_id)` | `uk_user_identities_provider_user` |
| 내 농장 목록 | `farm_members.user_id = ?` | `ix_farm_members_user` |
| 요청 권한 확인 | `farm_members (farm_id, user_id)` | `uk_farm_members_farm_user` |
| 장치 인증 | `devices.key_prefix = ?` → 해시 비교 | `uk_devices_key_prefix` |
| 구역의 현재 작물 | `plantings (farm_id, zone_id) AND status = 'ACTIVE'` | `ix_plantings_active` |
| 예보 조회 | `weather_forecasts (grid_id, forecast_at 범위)` | PK |
| 알림 생성(중복 확인) | `INSERT ... ON CONFLICT (farm_id, dedup_key) WHERE status = 'OPEN' DO NOTHING` | `uk_alerts_open_dedup` |
| 발송 대기 처리 | `status = 'PENDING' ORDER BY created_at` + `FOR UPDATE SKIP LOCKED` | `ix_notifications_pending` |
| 안 읽은 웹 알림 | `user_id, farm_id, channel = 'WEB', read_at IS NULL` | `ix_notifications_user_web` |

## 5. InfluxDB · Redis (참고)

DDL은 아니지만 저장 구조를 함께 정리한다.

### 5.1 InfluxDB — 센서 측정값

| 항목 | 값 |
|---|---|
| 조직 / 버킷 | `jinfarm` / `sensor` (보관 365일, `deploy/docker-compose.yml`에서 최초 생성) |
| measurement | `sensor` |
| tag | `farm_id`, `field_id`, `zone_id`, `device_id`, `metric` (구역 없는 장치는 `field_id`·`zone_id` 생략) |
| field | `value` (float) |
| time | 장치 측정 시각 (정밀도: 초) |

Line protocol 예:

```
sensor,farm_id=1,field_id=1,zone_id=3,device_id=12,metric=SOIL_MOISTURE value=34.5 1790753400
```

### 5.2 Redis — 토큰 · 캐시 · 최신 상태

| 키 | 타입 | 내용 | 만료 |
|---|---|---|---|
| `auth:*`, `kakao:token:{userId}` | — | JWT Refresh 토큰, 로그아웃한 Access 토큰, 로그인 실패 횟수, 카카오 토큰 | 키별 TTL — **[05-auth.md](05-auth.md) 4장** |
| `device:{deviceId}:state` | Hash | `last_seen_at`, `battery_pct`, `rssi`, 측정 종류별 최신값 | 없음 (장치 삭제 시 제거) |
| `device:state:dirty` | Set | PostgreSQL에 아직 반영하지 않은 장치 id | 반영 후 제거 |
| `farm:{farmId}:dashboard` | String(JSON) | 대시보드 요약 캐시 | 1분 |
| `chat:quota:farm:{farmId}:{yyyyMMdd}` | String (정수) | AI 챗봇 농장별 하루 질문 수 | 2일 |
| `chat:lock:user:{userId}` | String | 답변 생성 중 표시 (동시 질문 방지) | 2분 |
| `chat:cost:{yyyyMM}` | String (실수) | AI 챗봇 월 누적 비용(추정) — 예산 상한 판단 | 40일 |
| `weather:now:{gridId}` | Hash | 기상청 초단기실황 최신값 (`T1H` 기온, `REH` 습도, `RN1` 1시간 강수량, `PTY` 강수형태, `baseAt`) | 3시간 |

- 키 이름은 애플리케이션 코드 한 곳(상수)에서 관리한다.
- 토큰을 저장하므로 Redis는 **`noeviction`**(메모리가 차도 키를 지우지 않음)으로 운영한다. 캐시 키에는 반드시 TTL을 둔다.

## 6. 적용 순서 · 다음 작업

1. Flyway 의존성 추가, 이 문서 3장의 SQL을 `src/main/resources/db/migration/V1__init.sql`로 옮긴다.
2. 운영 `spring.jpa.hibernate.ddl-auto`를 `validate`로 변경 (02-infrastructure.md I5).
3. 로컬 개발(H2)도 같은 스키마를 쓰도록 **로컬도 PostgreSQL(Docker)로 전환**을 검토한다.
   부분 인덱스, `JSONB`, `COMMENT ON` 등 PostgreSQL 문법을 H2가 모두 지원하지 않기 때문이다. 테스트는 Testcontainers(PostgreSQL)로 실행한다.
