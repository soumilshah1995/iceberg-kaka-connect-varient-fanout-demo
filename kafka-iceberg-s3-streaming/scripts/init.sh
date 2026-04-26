#!/bin/bash
# Build Iceberg Kafka Connect runtime into ./kafka-connect/<RUNTIME_DIR_NAME>/.
# Writes ./kafka-connect/connect-worker-cp/hadoop-common-*.jar (copy for docker-compose bind to
# /usr/share/java/kafka/) and, after a successful build, one zip: iceberg-kafka-connect-bundle-<id>.zip
# containing: <RUNTIME_DIR_NAME>/ + connect-worker-cp/ — unzip into ./kafka-connect/ to match compose.
#
# Default: clone https://github.com/soumilshah1995/iceberg (branch: kafka-connect-auto-create-variant-columns).
#   Override: ICEBERG_REMOTE_URL, ICEBERG_REMOTE_REF, RUNTIME_DIR_NAME
# Local fork (bind-mount): USE_LOCAL_ICEBERG=1 — set ICEBERG_ROOT or use <monorepo>/iceberg
# Upstream Apache main: USE_APACHE_ICEUPSTREAM=1
# Skip shipping zip: SKIP_BUNDLE_ZIP=1
# Build is Gradle (./gradlew), not Maven. Unit/integration tests are already skipped: -x test -x integrationTest
# To skip more tasks (e.g. -x check), set:  GRADLE_BUILD_EXTRA_ARGS='-x check'
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "$SCRIPT_DIR/../kafka-connect" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STREAMING_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUNTIME_DIR_NAME="${RUNTIME_DIR_NAME:-iceberg-kafka-connect-runtime-844a0ab}"
# Fixed path for docker-compose bind: ./kafka-connect/connect-worker-cp/<name>
WORKER_CP_DIR_NAME="${WORKER_CP_DIR_NAME:-connect-worker-cp}"
WORKER_CP_JAR_NAME="${WORKER_CP_JAR_NAME:-hadoop-common-3.4.3.jar}"

ICEBERG_REMOTE_URL="${ICEBERG_REMOTE_URL:-https://github.com/soumilshah1995/iceberg.git}"
ICEBERG_REMOTE_REF="${ICEBERG_REMOTE_REF:-kafka-connect-auto-create-variant-columns}"
# Extra ./gradlew args (optional; appended after -x test -x integrationTest)
GRADLE_BUILD_EXTRA_ARGS="${GRADLE_BUILD_EXTRA_ARGS:-}"

# After distZip: enrich runtime lib (UGI) + one fixed-path hadoop JAR for docker-compose worker mount.
# Legacy *-hive-* sidecar is removed — everything needed lives under the runtime + connect-worker-cp.
prepare_connect_bundle_extras() {
  set +e
  local main_lib worker_cp_dir cc2_ver cc2_name maven main bn hadoop_ver auth_maven auth_name
  main_lib="$STREAMING_ROOT/kafka-connect/${RUNTIME_DIR_NAME}/lib"
  worker_cp_dir="$STREAMING_ROOT/kafka-connect/${WORKER_CP_DIR_NAME}"
  if [[ -d "$STREAMING_ROOT/kafka-connect/.connect-worker-cp" ]]; then
    if [[ ! -d "$worker_cp_dir" ]]; then
      mv "$STREAMING_ROOT/kafka-connect/.connect-worker-cp" "$worker_cp_dir" && echo "OK: renamed .connect-worker-cp -> ${WORKER_CP_DIR_NAME}" >&2
    else
      rm -rf "$STREAMING_ROOT/kafka-connect/.connect-worker-cp"
    fi
  fi
  cc2_ver="${COMMONS_CONFIGURATION2_VERSION:-2.10.1}"
  cc2_name="commons-configuration2-${cc2_ver}.jar"
  maven="https://repo1.maven.org/maven2/org/apache/commons/commons-configuration2/${cc2_ver}/commons-configuration2-${cc2_ver}.jar"

  local -a hc_jars
  hc_jars=( "$main_lib"/hadoop-common-*.jar )
  if [[ ! -e "${hc_jars[0]:-}" ]]; then
    echo "prepare_connect_bundle_extras: missing $main_lib/hadoop-common-*.jar" >&2
    return 1
  fi
  if [[ ${#hc_jars[@]} -gt 1 ]]; then
    echo "Note: multiple hadoop-common-*.jar; using: $(basename "${hc_jars[0]}")" >&2
  fi
  main="${hc_jars[0]}"
  bn="$(basename "$main" .jar)"
  hadoop_ver="${bn#hadoop-common-}"
  auth_maven="https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-auth/${hadoop_ver}/hadoop-auth-${hadoop_ver}.jar"
  auth_name="hadoop-auth-${hadoop_ver}.jar"

  mkdir -p "$main_lib" "$worker_cp_dir" || return 1
  cp -f "$main" "$worker_cp_dir/${WORKER_CP_JAR_NAME}" || return 1
  echo "OK: $worker_cp_dir/${WORKER_CP_JAR_NAME} (docker bind target; from $(basename "$main"))"
  if [[ "$(basename "$main")" != "hadoop-common-3.4.1.jar" ]]; then
    cp -f "$main" "$main_lib/hadoop-common-3.4.1.jar" || return 1
    echo "OK: $main_lib/hadoop-common-3.4.1.jar (copy of $(basename "$main"))"
  fi

  if [[ ! -f "$main_lib/$cc2_name" ]]; then
    echo "Downloading $cc2_name (Hadoop UGI)..."
    curl -fsSL "$maven" -o "$main_lib/$cc2_name" || return 1
  fi
  echo "OK: $cc2_name in $main_lib"

  if [[ ! -f "$main_lib/$auth_name" ]]; then
    echo "Downloading $auth_name..."
    curl -fsSL "$auth_maven" -o "$main_lib/$auth_name" || return 1
  fi
  echo "OK: $auth_name in $main_lib"
  set -e
  return 0
}

# Single zip: <RUNTIME_DIR_NAME>/ + connect-worker-cp/ (worker bind JAR) for handoff / unzip under kafka-connect/.
# Does not re-run Gradle; run after prepare_connect_bundle_extras.
create_shipping_zip() {
  if [[ "${SKIP_BUNDLE_ZIP:-0}" == "1" ]]; then
    echo "SKIP_BUNDLE_ZIP=1 — not creating distribution zip"
    return 0
  fi
  local id zipname
  id="${RUNTIME_DIR_NAME#iceberg-kafka-connect-runtime-}"
  zipname="iceberg-kafka-connect-bundle-${id}.zip"
  cd "$TARGET_DIR" || return 1
  if [[ ! -d "$RUNTIME_DIR_NAME" ]]; then
    echo "create_shipping_zip: missing $TARGET_DIR/$RUNTIME_DIR_NAME" >&2
    return 1
  fi
  if [[ ! -d "${WORKER_CP_DIR_NAME}" ]] || [[ ! -f "${WORKER_CP_DIR_NAME}/${WORKER_CP_JAR_NAME}" ]]; then
    echo "create_shipping_zip: run prepare_connect_bundle_extras first" >&2
    return 1
  fi
  rm -f "$zipname"
  if command -v zip >/dev/null 2>&1; then
    # shellcheck disable=SC2035
    zip -q -r "$zipname" "$RUNTIME_DIR_NAME" "$WORKER_CP_DIR_NAME"
  else
    echo "No zip(1) on PATH; install zip to write $TARGET_DIR/$zipname" >&2
    return 1
  fi
  echo "Shippable archive: $TARGET_DIR/$zipname ($(du -h "$zipname" 2>/dev/null | cut -f1 || echo "?"))"
  return 0
}

# --- Local Iceberg: bind-mount $ICEBERG_ROOT at /iceberg, output to TARGET_DIR (same as old docker-inner) ---
if [[ "${USE_LOCAL_ICEBERG:-0}" == "1" || "${USE_ICEBERG_FORK:-0}" == "1" ]]; then
  ICEBERG_ROOT="${ICEBERG_ROOT:-$REPO_ROOT/iceberg}"
  if [[ ! -f "$ICEBERG_ROOT/gradlew" ]] || [[ ! -d "$ICEBERG_ROOT/kafka-connect" ]]; then
    echo "ICEBERG_ROOT must be an Iceberg clone (gradlew + kafka-connect/). Got: $ICEBERG_ROOT" >&2
    exit 1
  fi
  echo "========================================================="
  echo "Local Iceberg (bind-mount) — $ICEBERG_ROOT → $TARGET_DIR/$RUNTIME_DIR_NAME"
  echo "========================================================="
  mkdir -p "$TARGET_DIR"
  cd "$TARGET_DIR"
  docker rm -f iceberg-kafka-fork-build 2>/dev/null || true
  rm -rf "$RUNTIME_DIR_NAME" 2>/dev/null || true
  rm -rf "$TARGET_DIR"/iceberg-kafka-connect-runtime-hive-* 2>/dev/null || true

  if docker run --name iceberg-kafka-fork-build \
    -e RUNTIME_DIR_NAME="$RUNTIME_DIR_NAME" \
    -e GRADLE_BUILD_EXTRA_ARGS="${GRADLE_BUILD_EXTRA_ARGS}" \
    -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
    -v "$ICEBERG_ROOT":/iceberg \
    -v "$TARGET_DIR":/output \
    eclipse-temurin:17-jdk \
    bash -c '
    set -euo pipefail
    if [[ ! -d /iceberg/kafka-connect ]] || [[ ! -f /iceberg/gradlew ]]; then
      echo "Invalid /iceberg: need gradlew and kafka-connect/" >&2
      exit 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    cd /iceberg
    echo "Building from /iceberg ($(git rev-parse --short HEAD 2>/dev/null || echo no-git)...)..."
    export GRADLE_OPTS="${GRADLE_OPTS:--Xmx3g -XX:MaxMetaspaceSize=512m}"
    chmod +x gradlew
    apt-get update -qq && apt-get install -y -qq git unzip
    ./gradlew :iceberg-kafka-connect:iceberg-kafka-connect-runtime:distZip -x test -x integrationTest $GRADLE_BUILD_EXTRA_ARGS --no-daemon
    DIST_DIR="kafka-connect/kafka-connect-runtime/build/distributions"
    set +o pipefail
    ZIP_FILE="$(ls -1 "$DIST_DIR"/iceberg-kafka-connect-runtime-*.zip 2>/dev/null | head -1)"
    set -o pipefail
    if [[ -z "${ZIP_FILE}" ]]; then
      echo "No ZIP under $DIST_DIR" >&2
      ls -la "$DIST_DIR" 2>&1 || true
      exit 1
    fi
    echo "Unzipping $ZIP_FILE..."
    rm -rf /output/unzipped
    mkdir -p /output/unzipped
    unzip -q -d /output/unzipped "$ZIP_FILE"
    set +o pipefail
    INNER="$(find /output/unzipped -mindepth 1 -maxdepth 1 -type d | head -1)"
    set -o pipefail
    if [[ -z "${INNER}" ]]; then
      echo "Unexpected zip layout" >&2
      find /output/unzipped -type f | head -20 >&2
      exit 1
    fi
    BAK="${RUNTIME_DIR_NAME}.bak.$(date +%Y%m%d%H%M%S)"
    if [[ -d "/output/${RUNTIME_DIR_NAME}" ]]; then
      echo "Backing up /output/${RUNTIME_DIR_NAME} -> /output/${BAK}"
      mv "/output/${RUNTIME_DIR_NAME}" "/output/${BAK}"
    fi
    mv "$INNER" "/output/${RUNTIME_DIR_NAME}"
    rm -rf /output/unzipped
    echo "Done. Runtime at /output/${RUNTIME_DIR_NAME}"
  '; then
    docker rm iceberg-kafka-fork-build 2>/dev/null || true
  else
    echo "Build failed" >&2
    docker rm -f iceberg-kafka-fork-build 2>/dev/null || true
    exit 1
  fi
  if ! prepare_connect_bundle_extras; then
    echo "Warning: prepare_connect_bundle_extras failed" >&2
  fi
  if ! create_shipping_zip; then
    echo "Warning: create_shipping_zip failed (install zip, or set SKIP_BUNDLE_ZIP=1)" >&2
  fi
  echo "Setup complete. Bundle: $TARGET_DIR/$RUNTIME_DIR_NAME (zip: iceberg-kafka-connect-bundle-*.zip)"
  echo "Restart Connect:  docker compose restart connect"
  exit 0
fi

echo "========================================================="
if [[ "${USE_APACHE_ICEUPSTREAM:-0}" == "1" ]]; then
  echo "USE_APACHE_ICEUPSTREAM=1 — cloning apache/iceberg (main) and building distZip..."
  ICEBERG_REMOTE_URL="https://github.com/apache/iceberg.git"
  ICEBERG_REMOTE_REF="main"
else
  echo "Default: fork build — $ICEBERG_REMOTE_URL @ $ICEBERG_REMOTE_REF"
  echo "  Local:  USE_LOCAL_ICEBERG=1 $0"
  echo "  Apache: USE_APACHE_ICEUPSTREAM=1 $0"
fi
echo "Target: $TARGET_DIR/$RUNTIME_DIR_NAME"
echo "========================================================="

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

echo "Cleaning up existing artifacts..."
docker rm -f iceberg-build 2>/dev/null || true
rm -rf iceberg *.jar *.zip lib iceberg-kafka-connect-runtime-hive-*
rm -rf "$RUNTIME_DIR_NAME" connect-worker-cp .connect-worker-cp

if docker run --name iceberg-build \
  -e RUNTIME_DIR_NAME="$RUNTIME_DIR_NAME" \
  -e ICEBERG_REMOTE_URL="$ICEBERG_REMOTE_URL" \
  -e ICEBERG_REMOTE_REF="$ICEBERG_REMOTE_REF" \
  -e GRADLE_BUILD_EXTRA_ARGS="${GRADLE_BUILD_EXTRA_ARGS}" \
  -v "$TARGET_DIR":/workspace \
  eclipse-temurin:17-jdk \
  bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    export GRADLE_OPTS="${GRADLE_OPTS:--Xmx3g -XX:MaxMetaspaceSize=512m}"
    cd /workspace
    echo "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq git unzip
    echo "Cloning $ICEBERG_REMOTE_URL (ref: $ICEBERG_REMOTE_REF)..."
    git clone --depth 1 --branch "$ICEBERG_REMOTE_REF" "$ICEBERG_REMOTE_URL" iceberg
    cd iceberg
    chmod +x gradlew
    echo "Building iceberg-kafka-connect-runtime distZip..."
    ./gradlew :iceberg-kafka-connect:iceberg-kafka-connect-runtime:distZip -x test -x integrationTest $GRADLE_BUILD_EXTRA_ARGS --no-daemon
    DIST_DIR="kafka-connect/kafka-connect-runtime/build/distributions"
    set +o pipefail
    ZIP_FILE="$(ls -1 "$DIST_DIR"/iceberg-kafka-connect-runtime-*.zip 2>/dev/null | head -1)"
    set -o pipefail
    if [[ -z "${ZIP_FILE}" ]]; then
      echo "No ZIP under $DIST_DIR" >&2
      ls -la "$DIST_DIR" 2>&1 || true
      exit 1
    fi
    echo "Unzipping $ZIP_FILE to /workspace/unzipped..."
    rm -rf /workspace/unzipped
    mkdir -p /workspace/unzipped
    unzip -q -d /workspace/unzipped "$ZIP_FILE"
    set +o pipefail
    INNER="$(find /workspace/unzipped -mindepth 1 -maxdepth 1 -type d | head -1)"
    set -o pipefail
    if [[ -z "${INNER}" ]]; then
      echo "Unexpected zip layout" >&2
      find /workspace/unzipped -type f | head -20 >&2
      exit 1
    fi
    rm -rf "/workspace/${RUNTIME_DIR_NAME}"
    mv "$INNER" "/workspace/${RUNTIME_DIR_NAME}"
    rm -rf /workspace/unzipped /workspace/iceberg
    echo "Done. Runtime at /workspace/${RUNTIME_DIR_NAME}"
  '; then
  echo "========================================================="
  echo "Build completed successfully!"
  echo "Cleaning up build container..."
  docker rm iceberg-build 2>/dev/null || true

  if ! prepare_connect_bundle_extras; then
    echo "Warning: prepare_connect_bundle_extras failed" >&2
  fi
  if ! create_shipping_zip; then
    echo "Warning: create_shipping_zip failed (install zip, or set SKIP_BUNDLE_ZIP=1)" >&2
  fi

  echo "Available artifacts in $TARGET_DIR:"
  ls -la "$TARGET_DIR"
  echo ""
  echo "Connector files in $TARGET_DIR/$RUNTIME_DIR_NAME/lib (sample):"
  ls -la "$TARGET_DIR/$RUNTIME_DIR_NAME/lib" 2>/dev/null | head -20 || true

  echo "========================================================="
  echo "Setup complete. Bundle: $TARGET_DIR/$RUNTIME_DIR_NAME (ship: iceberg-kafka-connect-bundle-*.zip)"
  echo "Restart Connect after replacing JARs:  docker compose restart connect"
  echo "========================================================="
else
  echo "========================================================="
  echo "Build failed!"
  docker rm -f iceberg-build 2>/dev/null || true
  exit 1
fi
