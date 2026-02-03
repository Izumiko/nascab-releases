FROM alpine:latest AS builder

WORKDIR /nascab

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories && \
    apk add --no-cache nodejs nodejs-dev npm python3 gcc g++ make cmake gfortran libffi-dev openssl-dev libtool vips-dev

COPY package.json ./

RUN npm config set registry https://registry.npmmirror.com && \
    npm config set fetch-retry-maxtimeout 120000 && \
    npm install || (echo "首次安装失败，等待10秒后重试..." && sleep 10 && npm install)

RUN find node_modules -type f \( -name "*.map" -o -name "*.md" -o -name "*.ts" \) -delete \
    && find node_modules -type d \( -name "__tests__" -o -name "test" -o -name "tests" -o -name "docs" \) -exec rm -rf {} + \
    && find node_modules -type d \( -name "assets" -o -name "images" \) -not -path "*/dist/*" -exec rm -rf {} +

FROM alpine:latest

WORKDIR /nascab

RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories && \
    apk add --no-cache nodejs ffmpeg vips-heif vips-tools vips-cpp

COPY --from=builder /nascab/node_modules ./node_modules
COPY . .

RUN chmod -R 755 /nascab/libs && \
    sed -i 's/"isDocker": false/"isDocker": true/' package.json

EXPOSE 21 80 90 443 9443

VOLUME ["/root/.local/share/nascab"]

CMD ["node", "app/main.js"]
