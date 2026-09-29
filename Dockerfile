# 빌드된 jar만 복사하는 런타임 이미지.
# jar는 CI에서 미리 빌드하므로 amd64/arm64(라즈베리파이) 이미지를 빠르게 만들 수 있다.
FROM eclipse-temurin:21-jre

RUN groupadd --system app && useradd --system --gid app app
WORKDIR /app
COPY target/jinfarm-*.jar app.jar
USER app

ENV SPRING_PROFILES_ACTIVE=prod \
    TZ=Asia/Seoul \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75"

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
