ARG NODE_IMAGE=node:24-trixie-slim
FROM ${NODE_IMAGE} AS base

ARG USE_CN_APT=0
ARG APT_MIRROR_HOST=mirrors.aliyun.com

RUN set -eux; \
    if [ "${USE_CN_APT}" = "1" ]; then \
      for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do \
        [ -f "$f" ] || continue; \
        sed -i \
          "s/deb.debian.org/${APT_MIRROR_HOST}/g; s/security.debian.org/${APT_MIRROR_HOST}/g" \
          "$f"; \
      done; \
    fi

FROM ypptec/nascabos:latest AS src

# -----------------------------------------------------------------------------
# Build stage: compilers, headers and npm exist only here.
# -----------------------------------------------------------------------------
FROM base AS build

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      python3 \
      pkg-config \
      libvips-dev \
      build-essential \
      cmake \
      gfortran \
      libffi-dev \
      libssl-dev \
      libtool

WORKDIR /nascabos

COPY --from=src /nascabos/package.json /nascabos/package-lock.json ./
COPY --from=src /nascabos/libs/logo.png ./libs/logo.png
COPY --from=src /nascabos/.npmrc ./.npmrc

ENV ONNXRUNTIME_NODE_INSTALL_CUDA=skip

RUN --mount=type=cache,target=/root/.npm \
    npm config set fetch-retry-maxtimeout 120000 \
    && npm config set fetch-retries 20 \
    && (npm install --omit=dev \
        || (echo "首次安装失败，等待10秒后重试..." \
            && sleep 10 \
            && npm install --omit=dev)) \
    && { rm -f \
      node_modules/onnxruntime-node/bin/napi-v3/linux/x64/libonnxruntime_providers_cuda.so \
      node_modules/onnxruntime-node/bin/napi-v3/linux/x64/libonnxruntime_providers_tensorrt.so \
      2>/dev/null || true; }

# node-addon-api is needed while compiling nodejieba. --omit=dev avoids
# accidentally restoring all devDependencies in this second npm install.
RUN --mount=type=cache,target=/root/.npm \
    npm install --omit=dev --no-save node-addon-api \
    && npm rebuild nodejieba --build-from-source \
    && npm prune --omit=dev

# clean up node_modules
RUN find node_modules -type f \( -name "*.map" -o -name "*.md" -o -name "*.ts" \) -delete \
    && find node_modules -type d \( -name "__tests__" -o -name "test" -o -name "tests" -o -name "docs" \) -prune -exec rm -rf -- {} +

# Copy application payload only after dependencies, preserving npm layer cache.
COPY --from=src /nascabos/app/ ./app/
COPY --from=src /nascabos/certs/ ./certs/
COPY --from=src /nascabos/web/ ./web/
COPY --from=src /nascabos/database/ ./database/
COPY --from=src /nascabos/onnx_models/ ./onnx_models/
COPY --from=src /nascabos/language/ ./language/
COPY --from=src /nascabos/libs/foliate-js-main/ ./libs/foliate-js-main/
COPY --from=src /nascabos/libs/rclone/linux/ ./libs/rclone/linux/
COPY --from=src /nascabos/libs/sftpgo/linux/ ./libs/sftpgo/linux/
COPY --from=src /nascabos/libs/openlist/linux/ ./libs/openlist/linux/
COPY --from=src /nascabos/libs/256x256.png ./libs/256x256.png
COPY --from=src /nascabos/libs/logo-tray.png ./libs/logo-tray.png
COPY --from=src /nascabos/libs/logo.ico ./libs/logo.ico
COPY --from=src /nascabos/libs/logo.png ./libs/logo.png
COPY --from=src /nascabos/libs/transcodetest_h264 ./libs/transcodetest_h264
COPY --from=src /nascabos/libs/transcodetest_h265 ./libs/transcodetest_h265
COPY --from=src /nascabos/libs/tray-linux.png ./libs/tray-linux.png
COPY --from=src /nascabos/libs/tray-mac.png ./libs/tray-mac.png
COPY --from=src /nascabos/libs/tray-mac@2x.png ./libs/tray-mac@2x.png
COPY --from=src /nascabos/libs/tray-mac@3x.png ./libs/tray-mac@3x.png
COPY --from=src /nascabos/libs/tray-win.png ./libs/tray-win.png
COPY --from=src /nascabos/VERSION /nascabos/apply-docker-version.js ./

RUN node ./apply-docker-version.js \
    && rm -f ./.npmrc ./apply-docker-version.js

# Validate the native modules in the environment where they were compiled.
RUN node -e "const m=['bcrypt','better-sqlite3','sharp','onnxruntime-node','nodejieba','node-pty']; for (const x of m){try{require(x); console.log('native build ok:',x);}catch(e){console.error('native build FAIL:',x,e&&e.message); process.exit(1);}}"

# -----------------------------------------------------------------------------
# Runtime stage: no compiler, headers, Python or build-only APT packages.
# -----------------------------------------------------------------------------
FROM base AS runtime

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      tzdata \
      libvips-tools \
      libheif1 \
      ffmpeg \
      vainfo \
      libva2 \
      mesa-va-drivers

WORKDIR /nascabos

COPY --from=build /nascabos/ /nascabos/

ENV ONNXRUNTIME_NODE_INSTALL_CUDA=skip \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

# The original image hides npm in the runtime image. This is retained for
# behavioral/security parity; because npm belongs to the base layer, this does
# not materially reduce the image's stored byte count.
RUN rm -rf \
      /usr/local/lib/node_modules/npm \
      /usr/local/bin/npm \
      /usr/local/bin/npx \
    && node -e "const m=['bcrypt','better-sqlite3','sharp','onnxruntime-node','nodejieba','node-pty']; for (const x of m){try{require(x); console.log('native runtime ok:',x);}catch(e){console.error('native runtime FAIL:',x,e&&e.message); process.exit(1);}}"

EXPOSE 10080 10443 2022 2121 6789 6799

VOLUME ["/nascabos_data"]

CMD ["node", "app/main_nascab_os.js"]
