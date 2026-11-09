#!/usr/bin/env bash
# 影策（open-ai-canvas）在 CNB 云原生开发环境里的一键启动脚本
# 被 .cnb.yml 的 options.launch 调用，daemon 模式后台托管。
set -uo pipefail

cd /workspace || { echo "[FATAL] /workspace 不存在"; exit 1; }
TAG="1.8.3"
DATA="/workspace/.yingce-data"
LOG="/workspace/.yingce-data/launch.log"
mkdir -p "$DATA"/{postgres,backend,redis,web}
exec > >(tee -a "$LOG") 2>&1

echo "===== $(date -Is) 启动影策 ====="

# ---------- 1. 环境自检 ----------
command -v docker >/dev/null 2>&1 || { echo "[FATAL] 没有 docker CLI，需在 .cnb.yml 的 services 里声明 docker"; exit 1; }
docker version >/dev/null 2>&1 || { echo "[FATAL] docker daemon 未就绪"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "[FATAL] 缺少 docker compose 插件"; exit 1; }
echo "[OK] docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) / $(docker compose version --short 2>/dev/null)"

# ---------- 2. 生成 .env（幂等，已存在则复用，保证数据卷密码不变） ----------
if [[ ! -f .env ]]; then
    PW="$(openssl rand -hex 32)"
    TOKEN="$(openssl rand -hex 32)"
    cat > .env <<EOF
POSTGRES_DB=open_ai_canvas
POSTGRES_USER=open_ai_canvas
POSTGRES_PASSWORD=${PW}
DATABASE_URL=postgresql://open_ai_canvas:${PW}@postgres:5432/open_ai_canvas?sslmode=disable
CANVAS_HTTP_PORT=8686
CANVAS_IMAGE_TAG=${TAG}
CANVAS_BACKEND_IMAGE=ghcr.io/ddcat-ai/open-ai-canvas-backend:${TAG}
CANVAS_WEB_IMAGE=ghcr.io/ddcat-ai/open-ai-canvas-web:${TAG}
CANVAS_YINGCE_AGENT_IMAGE=ghcr.io/ddcat-ai/open-ai-canvas-yingce-agent:${TAG}
YINGCE_AGENT_TOKEN=${TOKEN}
CANVAS_REGISTRATION_ENABLED=true
CANVAS_ALLOW_PRIVATE_UPSTREAMS=false
CANVAS_ALLOWED_PRIVATE_UPSTREAM_HOSTS=
CANVAS_CORS_ORIGINS=
CANVAS_POSTGRES_DATA_PATH=${DATA}/postgres
CANVAS_DATA_PATH=${DATA}/backend
CANVAS_REDIS_DATA_PATH=${DATA}/redis
CANVAS_WEB_DATA_PATH=${DATA}/web
EOF
    echo "[OK] 已生成 .env（数据库密码随机）"
else
    echo "[OK] 复用已有 .env"
fi

# ---------- 3. 拉镜像（多个 ghcr 源依次尝试，兼容国内网络） ----------
pull_image() {
    local repo="$1"   # ddcat-ai/open-ai-canvas-backend
    local target="ghcr.io/${repo}:${TAG}"
    if docker image inspect "$target" >/dev/null 2>&1; then
        echo "[OK] 本地已有 ${repo}"
        return 0
    fi
    local mirror
    for mirror in ghcr.io ghcr.m.daocloud.io ghcr.nju.edu.cn; do
        echo "[..] 尝试 ${mirror}/${repo}:${TAG}"
        if timeout 600 docker pull "${mirror}/${repo}:${TAG}"; then
            if [[ "$mirror" != "ghcr.io" ]]; then
                docker tag "${mirror}/${repo}:${TAG}" "$target"
            fi
            echo "[OK] ${repo} 来自 ${mirror}"
            return 0
        fi
        echo "[!!] ${mirror} 失败，换下一个"
    done
    echo "[FATAL] 所有源都拉不到 ${repo}"
    return 1
}

pull_image ddcat-ai/open-ai-canvas-backend || exit 1
pull_image ddcat-ai/open-ai-canvas-web || exit 1
pull_image ddcat-ai/open-ai-canvas-yingce-agent || exit 1

# ---------- 4. 起服务 ----------
docker compose --env-file .env -f docker-compose.deploy.yml up -d --remove-orphans
echo "[..] 等待健康检查"
docker compose --env-file .env -f docker-compose.deploy.yml ps

# ---------- 5. 确认 8686 在监听 ----------
for i in $(seq 1 60); do
    if curl -fsS -m 3 "http://127.0.0.1:8686/" -o /dev/null 2>/dev/null; then
        echo "[OK] 前端已在 8686 就绪（第 ${i} 次探测）"
        break
    fi
    sleep 3
done

echo "===== 启动结束，预览地址由 CNB 提供 ====="
docker compose --env-file .env -f docker-compose.deploy.yml logs --tail=20 backend 2>/dev/null || true
