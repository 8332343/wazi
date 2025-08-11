#!/bin/bash
# Docker容器一键备份脚本（修复参数过长问题）
# 备份所有镜像和卷数据

set -e  # 出错时自动退出

# 创建带时间戳的备份目录
BACKUP_DIR="/tmp/docker-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "备份目录: $BACKUP_DIR"

# 1. 分批备份所有Docker镜像（修复参数过长问题）
echo "正在分批备份Docker镜像..."
IMAGE_FILE="$BACKUP_DIR/image-list.txt"
docker images --format "{{.ID}}" | sort -u > "$IMAGE_FILE"

total_images=$(wc -l < "$IMAGE_FILE")
batch_size=50
batches=$(( (total_images + batch_size - 1) / batch_size ))

for ((i=0; i<batches; i++)); do
    start=$((i * batch_size + 1))
    end=$((start + batch_size - 1))
    
    echo "备份镜像批次 $((i+1))/$batches ($start-$end)"
    batch_ids=$(sed -n "${start},${end}p" "$IMAGE_FILE" | tr '\n' ' ')
    
    if [ -n "$batch_ids" ]; then
        docker save $batch_ids -o "$BACKUP_DIR/images-batch-$((i+1)).tar"
    fi
done

# 2. 备份所有容器配置
echo "正在备份容器配置..."
mkdir -p "$BACKUP_DIR/containers"
docker ps -a --format '{{.Names}}' | while read container; do
    echo "备份容器: $container"
    docker inspect "$container" > "$BACKUP_DIR/containers/${container}-config.json"
done

# 3. 备份所有数据卷
echo "正在备份Docker卷..."
mkdir -p "$BACKUP_DIR/volumes"
docker volume ls -q | while read volume; do
    echo "备份卷: $volume"
    docker run --rm -v "$volume":/volume -v "$BACKUP_DIR/volumes":/backup alpine \
        tar czf "/backup/${volume}-backup.tar.gz" -C /volume ./
done

# 4. 备份网络配置
echo "正在备份网络配置..."
mkdir -p "$BACKUP_DIR/networks"
docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | while read network; do
    echo "备份网络: $network"
    docker network inspect "$network" > "$BACKUP_DIR/networks/network-${network}.json"
done

# 5. 创建恢复脚本
cat > "$BACKUP_DIR/restore.sh" << 'EOF'
#!/bin/bash
# Docker容器一键恢复脚本

if [ $# -ne 1 ]; then
    echo "用法: $0 <备份目录路径>"
    exit 1
fi

BACKUP_DIR="$1"

# 1. 恢复所有镜像
if [ -d "$BACKUP_DIR" ]; then
    echo "正在恢复Docker镜像..."
    find "$BACKUP_DIR" -name 'images-batch-*.tar' | while read image_file; do
        echo "加载镜像文件: $(basename "$image_file")"
        docker load -i "$image_file"
    done
fi

# 2. 恢复所有数据卷
if [ -d "$BACKUP_DIR/volumes" ]; then
    echo "正在恢复Docker卷..."
    find "$BACKUP_DIR/volumes" -name '*.tar.gz' | while read backup_file; do
        volume_name=$(basename "$backup_file" "-backup.tar.gz")
        echo "恢复卷: $volume_name"
        docker volume create "$volume_name" >/dev/null
        docker run --rm -v "$volume_name":/volume -v "$(dirname "$backup_file")":/backup alpine \
            tar xzf "/backup/$(basename "$backup_file")" -C /volume
    done
fi

# 3. 恢复容器配置
if [ -d "$BACKUP_DIR/containers" ]; then
    echo "正在恢复容器配置..."
    find "$BACKUP_DIR/containers" -name '*-config.json' | while read config_file; do
        container_name=$(basename "$config_file" "-config.json")
        echo "恢复容器: $container_name"
        image_name=$(jq -r '.[0].Config.Image' "$config_file")
        restart_policy=$(jq -r '.[0].HostConfig.RestartPolicy.Name' "$config_file")
        
        docker create --name "$container_name" "$image_name" >/dev/null
        docker update --restart "$restart_policy" "$container_name"
    done
fi

# 4. 恢复网络配置
if [ -d "$BACKUP_DIR/networks" ]; then
    echo "正在恢复网络配置..."
    find "$BACKUP_DIR/networks" -name 'network-*.json' | while read network_file; do
        network_name=$(basename "$network_file" ".json" | sed 's/^network-//')
        driver_type=$(jq -r '.[0].Driver' "$network_file")
        
        echo "恢复网络: $network_name"
        docker network create --driver "$driver_type" "$network_name"
    done
fi

echo "恢复完成！请手动启动容器: docker start [容器名]"
EOF

chmod +x "$BACKUP_DIR/restore.sh"

# 压缩备份文件
echo "正在压缩备份文件..."
tar czf "$BACKUP_DIR.tar.gz" -C "$BACKUP_DIR" .
rm -rf "$BACKUP_DIR"

echo "备份完成！请复制文件到新服务器:"
echo "备份文件: $BACKUP_DIR.tar.gz"
echo "恢复命令:"
echo "  1. tar xzf $BACKUP_DIR.tar.gz"
echo "  2. cd docker-backup-*"
echo "  3. ./restore.sh ."
