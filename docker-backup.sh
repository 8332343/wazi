#!/bin/bash
# Docker容器一键备份脚本
# 备份所有镜像和卷数据

set -e  # 出错时自动退出

# 创建带时间戳的备份目录
BACKUP_DIR="/tmp/docker-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "备份目录: $BACKUP_DIR"

# 1. 备份所有Docker镜像
echo "正在备份Docker镜像..."
docker save $(docker images -q) -o "$BACKUP_DIR/docker-images.tar" 2>/dev/null || {
    echo "警告：镜像备份失败（可能是没有镜像）"
}

# 2. 备份所有容器配置
echo "正在备份容器配置..."
docker ps -a --format '{{.Names}}' | while read container; do
    docker inspect "$container" > "$BACKUP_DIR/${container}-config.json"
done

# 3. 备份所有数据卷
echo "正在备份Docker卷..."
docker volume ls -q | while read volume; do
    echo "备份卷: $volume"
    docker run --rm -v "$volume":/volume -v "$BACKUP_DIR":/backup alpine \
        tar czf "/backup/${volume}-backup.tar.gz" -C /volume ./
done

# 4. 备份网络配置
echo "正在备份网络配置..."
docker network ls --format '{{.Name}}' | grep -v 'bridge\|host\|none' | while read network; do
    docker network inspect "$network" > "$BACKUP_DIR/network-${network}.json"
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
if [ -f "$BACKUP_DIR/docker-images.tar" ]; then
    echo "正在恢复Docker镜像..."
    docker load -i "$BACKUP_DIR/docker-images.tar"
fi

# 2. 恢复所有数据卷
echo "正在恢复Docker卷..."
find "$BACKUP_DIR" -name '*-backup.tar.gz' | while read backup_file; do
    volume_name=$(basename "$backup_file" "-backup.tar.gz")
    echo "恢复卷: $volume_name"
    docker volume create "$volume_name" >/dev/null
    docker run --rm -v "$volume_name":/volume -v "$BACKUP_DIR":/backup alpine \
        tar xzf "/backup/$(basename $backup_file)" -C /volume
done

# 3. 恢复容器配置
echo "正在恢复容器配置..."
find "$BACKUP_DIR" -name '*-config.json' | while read config_file; do
    container_name=$(basename "$config_file" "-config.json")
    echo "恢复容器: $container_name"
    docker create --name "$container_name" $(jq -r '.[0].Config.Image' "$config_file") >/dev/null
    docker update --restart $(jq -r '.[0].HostConfig.RestartPolicy.Name' "$config_file") "$container_name"
done

# 4. 恢复网络配置
echo "正在恢复网络配置..."
find "$BACKUP_DIR" -name 'network-*.json' | while read network_file; do
    network_name=$(basename "$network_file" ".json" | sed 's/^network-//')
    echo "恢复网络: $network_name"
    docker network create "$network_name" $(jq -r '.[0].Driver' "$network_file")
done

echo "恢复完成！请手动启动容器: docker start [容器名]"
EOF

chmod +x "$BACKUP_DIR/restore.sh"

# 压缩备份文件
echo "正在压缩备份文件..."
tar czf "$BACKUP_DIR.tar.gz" -C "$BACKUP_DIR" .
rm -rf "$BACKUP_DIR"

echo "备份完成！请复制文件到新服务器:"
echo "备份文件: $BACKUP_DIR.tar.gz"
echo "恢复命令: ./restore.sh [解压后的目录]"
