# JinFarm 인증 · 토큰 설계

> 작성일: 2026-09-30 · 상태: 초안 (v0.1)
> 관련: [01-features.md](01-features.md) 2.1 · [04-domain-model.md](04-domain-model.md) · [04-ddl.md](04-ddl.md)

## 1. 결정 사항

| 항목 | 결정 |
|---|---|
| 로그인 수단 | **카카오 로그인** + **아이디/비밀번호** (둘 다 1단계) |
| 로그인 이후 인증 | 로그인 수단과 관계없이 **우리 서버가 JWT를 발급** (Access + Refresh) |
| 토큰 저장소 | **Redis** — JWT Refresh 토큰, 로그아웃한 Access 토큰, 카카오 토큰, 로그인 실패 횟수, 카카오 로그인 1회용 코드 |
| PostgreSQL | 사용자·로그인 수단(계정 연결)만 저장. 토큰은 저장하지 않는다 (`kakao_tokens` 테이블 삭제) |
| 비밀번호 | BCrypt 해시 (Spring Security `DelegatingPasswordEncoder` 기본값) |

## 2. 계정 모델

한 사용자(`users`)가 **여러 로그인 수단**을 가질 수 있다.

```
users (1) ──┬── 아이디/비밀번호   users.login_id, users.password_hash (선택)
            └── 소셜 계정 (N)     user_identities (provider = KAKAO, 이후 GOOGLE, NAVER)
```

| 가입 경로 | 생기는 것 | 이후 |
|---|---|---|
| 카카오로 가입 | `users` + `user_identities(KAKAO)` | 원하면 아이디/비밀번호 추가 (P1) |
| 아이디/비밀번호로 가입 | `users(login_id, password_hash)` | 로그인 후 **카카오 연결** 가능 (카카오톡 알림을 받으려면 필요) |

- 로그인 수단이 하나도 없는 사용자가 생기지 않도록, 마지막 로그인 수단은 해제할 수 없다 (애플리케이션에서 보장).
- **카카오톡 알림(ALM-05)은 카카오 계정이 연결되고 메시지 전송에 동의한 사용자만** 받는다. 아이디/비밀번호 전용 사용자는 웹 알림만 받고, 알림 설정 화면에서 카카오 연결을 안내한다.
- 아이디는 이메일이 아닌 **영문·숫자 아이디**로 한다 (1단계에는 메일 발송 인프라가 없어 이메일 인증을 할 수 없음). 비밀번호 찾기는 이메일 인증을 도입할 때 추가한다 (P1).

### 2.1 아이디 · 비밀번호 규칙

| 항목 | 규칙 |
|---|---|
| 아이디 | 영문 소문자로 시작, 영문 소문자·숫자·`_` 4~20자. 대소문자 구분 없음(소문자로 저장) |
| 비밀번호 | 8~64자, 영문과 숫자 포함. 아이디와 같으면 거부 |
| 로그인 실패 | 같은 아이디로 **15분 안에 5회** 실패 시 15분 잠금 (Redis 카운터) |
| 오류 메시지 | 아이디가 없는 경우와 비밀번호가 틀린 경우를 **구분하지 않고** "아이디 또는 비밀번호가 올바르지 않습니다" |

## 3. JWT

### 3.1 토큰 종류

| 토큰 | 형식 | 유효 기간 | 전달 방식 | 서버 저장 |
|---|---|---|---|---|
| **Access** | JWT (HS256) | **30분** | 응답 본문 → 클라이언트가 메모리에 보관, `Authorization: Bearer` 헤더로 전송 | 저장 안 함. 로그아웃 시에만 차단 목록에 등록 |
| **Refresh** | JWT (HS256) | **14일** | `HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/api/auth` 쿠키 | **Redis** (허용 목록) |

- Access 토큰을 `localStorage`에 두지 않는다 (XSS로 탈취 방지). 새로고침하면 Refresh 쿠키로 다시 발급받는다.
- Refresh 쿠키는 `/api/auth` 경로에만 전송되고 `SameSite=Strict`라 다른 사이트에서의 요청(CSRF)에 쓰이지 않는다.
- 서명 키 `JWT_SECRET`은 서버 `.env`에만 두고 256비트 이상 무작위 값으로 생성한다.

### 3.2 Claim

| claim | Access | Refresh | 설명 |
|---|---|---|---|
| `sub` | ✅ | ✅ | 사용자 id |
| `jti` | ✅ | ✅ | 토큰 고유 id (UUID) |
| `typ` | `access` | `refresh` | Refresh 토큰을 API 인증에 쓰지 못하게 구분 |
| `iat`, `exp` | ✅ | ✅ | 발급·만료 시각 |
| `fam` | | ✅ | Refresh 토큰 계열 id (재사용 탐지용, 3.4) |

- **농장·역할은 토큰에 넣지 않는다.** 역할이 바뀌거나 농장에서 제외되면 즉시 반영되어야 하므로, 매 요청마다 `farm_members`로 확인한다 (USR-05).
- 현재 농장은 요청 경로(`/api/farms/{farmId}/...`)로 전달한다.

### 3.3 흐름

**아이디/비밀번호 로그인**

```
브라우저 ── POST /api/auth/login {loginId, password} ──▶ 서버
                                                         ├ 잠금 확인 (Redis auth:login-fail)
                                                         ├ 비밀번호 확인 (BCrypt)
                                                         ├ Refresh 저장 (Redis)
브라우저 ◀── 200 {accessToken} + Set-Cookie: refresh ────┘
```

**카카오 로그인** (Spring Security OAuth2 Client)

```
브라우저 ── GET /oauth2/authorization/kakao ──▶ 카카오 로그인·동의 화면
카카오 ── GET /login/oauth2/code/kakao?code=... ──▶ 서버
                                                    ├ 카카오 토큰 받기 → 사용자 정보 조회
                                                    ├ user_identities로 사용자 찾기 / 없으면 가입
                                                    ├ 카카오 토큰 저장 (Redis kakao:token)
                                                    ├ 1회용 코드 발급 (Redis, 60초)
브라우저 ◀── 302 /login/callback?code=1회용코드 ────┘
브라우저 ── POST /api/auth/exchange {code} ──▶ 서버: 코드 삭제(1회) → Access + Refresh 발급
```

- JWT를 URL에 직접 싣지 않는다 (브라우저 기록·서버 로그에 남음). 60초짜리 1회용 코드만 URL로 전달한다.
- OAuth2 로그인 과정의 `state` 값 보관에만 세션을 쓰고, 로그인이 끝나면 세션을 쓰지 않는다 (`SessionCreationPolicy.IF_REQUIRED`, API는 JWT만 인정).

**토큰 재발급 · 로그아웃**

| 요청 | 동작 |
|---|---|
| `POST /api/auth/refresh` (Refresh 쿠키) | Refresh 확인 → **기존 Refresh 삭제 후 새 Refresh·Access 발급** (Rotation) |
| `POST /api/auth/logout` | 현재 Refresh 삭제 + 현재 Access를 차단 목록에 등록 + 쿠키 삭제 |
| `POST /api/auth/logout-all` | 이 사용자의 모든 Refresh 삭제 (모든 기기 로그아웃) |
| 비밀번호 변경 · 회원 탈퇴 | 모든 Refresh 삭제 |

### 3.4 Refresh 토큰 재사용 탐지

Refresh 토큰은 한 번 쓰면 폐기된다(Rotation). 이미 폐기된 Refresh 토큰이 다시 들어오면 **탈취된 것으로 보고** 같은 계열(`fam`)의 토큰을 모두 폐기해 해당 기기를 로그아웃시킨다.

```
정상:   R1 사용 → R1 삭제, R2 발급 → R2 사용 → R2 삭제, R3 발급 ...
탈취:   공격자가 R1을 훔쳐 둠 → 사용자가 R1 사용(R2 발급) → 공격자가 R1 사용
        → R1은 Redis에 없는데 서명은 유효 → 재사용 → 계열 전체 폐기 → 사용자·공격자 모두 재로그인
```

## 4. Redis 키

| 키 | 타입 | 값 | TTL |
|---|---|---|---|
| `auth:refresh:{jti}` | Hash | `userId`, `family`, `issuedAt`, `userAgent`, `ip` | Refresh 만료까지 (14일) |
| `auth:family:{familyId}` | Set | 이 계열에서 발급된 Refresh `jti` | Refresh 만료까지 |
| `auth:user:{userId}:families` | Set | 사용자의 로그인 계열 id (기기별) | 갱신 시 14일로 연장 |
| `auth:blacklist:{jti}` | String | `1` | Access 남은 유효 시간 |
| `auth:login-fail:{loginId}` | String (정수) | 연속 실패 횟수 | 15분 |
| `auth:oauth-code:{code}` | String | `userId` | 60초 (`GETDEL`로 1회만 사용) |
| `kakao:token:{userId}` | Hash | `accessToken`, `refreshToken` (암호화), `accessExpiresAt`, `refreshExpiresAt`, `scopes`, `talkMessageAgreed` | 카카오 Refresh 토큰 만료까지 (약 2개월) |

- Refresh 사용·폐기는 `GETDEL` 또는 Lua 스크립트로 **원자적으로** 처리한다 (같은 토큰으로 동시에 두 번 재발급되는 것 방지).
- 카카오 토큰은 Redis에 있어도 **애플리케이션에서 AES-GCM으로 암호화**해서 저장한다 (키: `TOKEN_ENC_KEY`).
- 카카오 Access 토큰이 만료되면 알림 발송 전에 Refresh 토큰으로 갱신하고, 카카오가 새 Refresh 토큰을 주면 함께 교체한다. 카카오 Refresh 토큰까지 만료되면 사용자가 다시 카카오 로그인해야 하므로 웹 알림으로 안내한다.

### 4.1 Redis를 토큰 저장소로 쓸 때의 운영 조건

| 조건 | 설정 | 이유 |
|---|---|---|
| **메모리가 차도 키를 지우지 않음** | `maxmemory-policy noeviction` ([deploy/docker-compose.yml](../deploy/docker-compose.yml)) | 캐시와 달리 토큰이 임의로 지워지면 사용자가 로그아웃되고, 카카오 토큰이 지워지면 카톡 알림이 끊긴다 |
| 영속화 | AOF (`appendonly yes`, 적용됨) | 재시작 시 토큰 유지 |
| 백업 | Redis 데이터 백업을 `backup.sh`에 추가 (02-infrastructure.md I6) | **Redis 데이터를 잃으면**: 모든 사용자가 다시 로그인, 카카오 연결 사용자는 카톡 알림 재동의 필요 |
| 캐시 키 분리 | 캐시 키(`farm:*:dashboard` 등)에는 반드시 TTL | `noeviction`이라 TTL 없는 캐시가 쌓이면 메모리가 찬다 |

## 5. 권한 확인

| 경로 | 인증 |
|---|---|
| `/`, `/index.html`, `/actuator/health/**`, `/actuator/info` | 공개 (서버 상태 페이지) |
| `/api/auth/signup`, `/api/auth/login`, `/api/auth/refresh`, `/api/auth/exchange`, `/oauth2/**`, `/login/oauth2/**` | 공개 |
| `/api/**` | Access 토큰 필요 |
| `/api/farms/{farmId}/**` | Access 토큰 + `farm_members`에 소속 확인. 역할별 권한(USR-06, P1)은 같은 지점에서 확인 |
| 장치 통신 (MQTT) | JWT가 아니라 **장치 키**로 인증 (04-domain-model.md 3.2) |

Access 토큰 검증 순서: 서명 → `exp` → `typ = access` → Redis 차단 목록(`auth:blacklist:{jti}`) → 사용자 존재·탈퇴 여부.

## 6. 설정 값

| 환경변수 | 설명 | 생성 |
|---|---|---|
| `JWT_SECRET` | JWT 서명 키 (HS256, 256비트 이상) | `server-setup.sh`가 무작위 생성 (구현 시 추가) |
| `TOKEN_ENC_KEY` | 카카오 토큰 암호화 키 (AES-256) | 〃 |
| `KAKAO_CLIENT_ID` | 카카오 REST API 키 | 카카오 개발자 콘솔에서 발급, 직접 입력 |
| `KAKAO_CLIENT_SECRET` | 카카오 Client Secret | 〃 |

| 설정 | 기본값 |
|---|---|
| Access 유효 기간 | 30분 |
| Refresh 유효 기간 | 14일 |
| 로그인 실패 잠금 | 15분 내 5회 → 15분 |
| 카카오 로그인 1회용 코드 | 60초 |

카카오 개발자 콘솔 설정 (구현 시):
- 동의 항목: 닉네임, 프로필 사진, **카카오톡 메시지 전송(`talk_message`)**
- Redirect URI: `http://localhost:8080/login/oauth2/code/kakao` (개발), 운영 도메인은 도메인 구매 후 추가 (02-infrastructure.md I4)

## 7. 기능 명세 반영

| ID | 기능 | 우선순위 |
|---|---|---|
| USR-01 | 카카오 로그인 → JWT 발급 | P0 |
| USR-10 | 아이디/비밀번호 회원가입·로그인 → JWT 발급 | P0 |
| USR-11 | 토큰 재발급(Rotation)·로그아웃·모든 기기 로그아웃 | P0 |
| USR-12 | 계정 연결: 아이디 사용자의 카카오 연결 / 카카오 사용자의 아이디·비밀번호 추가 | 카카오 연결 P0, 아이디 추가 P1 |
| USR-13 | 비밀번호 변경 | P1 |
| USR-14 | 비밀번호 찾기 (이메일 인증) | P2 |
