#!/bin/bash

set -e

# 色付きログ用の定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ロールバック関数
rollback() {
    local reason=$1
    log_error "ロールバックを実行します: $reason"
    
    # 稼働中のコンテナを取得
    RUNNING_CONTAINERS=$(docker compose ps -q app 2>/dev/null)
    RUNNING_COUNT=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
    
    # 停止中のコンテナを取得
    STOPPED_CONTAINERS=$(docker compose ps -aq app 2>/dev/null | grep -v -F "$RUNNING_CONTAINERS" || true)
    STOPPED_COUNT=$(echo "$STOPPED_CONTAINERS" | grep -v '^$' | wc -l | tr -d ' ')
    
    if [ "$RUNNING_COUNT" -gt 0 ] && [ "$STOPPED_COUNT" -gt 0 ]; then
        # ケース1: 停止中のコンテナがある場合、それを再起動して新しいコンテナを削除
        log_info "停止中のコンテナを再起動します"
        
        for container_id in $STOPPED_CONTAINERS; do
            if [ -n "$container_id" ]; then
                CONTAINER_NAME=$(docker inspect --format='{{.Name}}' $container_id 2>/dev/null | sed 's/\///' || echo "")
                if [ -n "$CONTAINER_NAME" ]; then
                    log_info "再起動中: $CONTAINER_NAME"
                    docker start $container_id >/dev/null 2>&1 || true
                fi
            fi
        done
        
        # 新しいコンテナを削除
        for container_id in $RUNNING_CONTAINERS; do
            CONTAINER_NAME=$(docker inspect --format='{{.Name}}' $container_id 2>/dev/null | sed 's/\///')
            log_info "新バージョンのコンテナを削除中: $CONTAINER_NAME"
            docker stop $container_id >/dev/null 2>&1 || true
            docker rm $container_id >/dev/null 2>&1 || true
        done
        
        log_success "ロールバック完了（旧バージョンに復帰）"
        
    elif [ "$RUNNING_COUNT" -gt 1 ]; then
        # ケース2: 複数のコンテナが稼働中の場合、最新のものを削除
        LATEST_CONTAINER=$(echo "$RUNNING_CONTAINERS" | tail -n 1)
        CONTAINER_NAME=$(docker inspect --format='{{.Name}}' $LATEST_CONTAINER 2>/dev/null | sed 's/\///')
        
        log_info "新バージョンのコンテナを削除中: $CONTAINER_NAME"
        docker stop $LATEST_CONTAINER >/dev/null 2>&1 || true
        docker rm $LATEST_CONTAINER >/dev/null 2>&1 || true
        
        log_success "ロールバック完了"
        
    else
        log_warning "ロールバック対象のコンテナがありません"
        log_info "停止中のコンテナ: $STOPPED_COUNT, 稼働中のコンテナ: $RUNNING_COUNT"
    fi
    
    # 現在の状態を表示
    echo ""
    log_info "現在の状態:"
    docker compose ps app 2>&1 | grep -v "^time="
    
    # 統計情報を表示
    sleep 3
    echo ""
    log_info "アプリケーション情報:"
    curl -s http://localhost/stats 2>/dev/null | jq '{version, active_requests}' || log_warning "統計情報の取得に失敗しました"
}

# 使用方法を表示
show_usage() {
    cat << EOF
使用方法: $0 [COMMAND] [VERSION] [OPTIONS]

コマンド:
  deploy               デプロイを実行（デフォルト）
  rollback             最新のデプロイをロールバック

引数:
  VERSION               デプロイするバージョン番号（省略時は日時を使用）

オプション:
  --verify             デプロイ中に継続的なリクエストを送信して検証
  -h, --help           このヘルプを表示

例:
  $0 deploy 2.0.0             # バージョン2.0.0にデプロイ
  $0 deploy 2.0.0 --verify    # 検証しながらデプロイ
  $0 rollback                 # 最新のデプロイをロールバック
  $0                          # タイムスタンプバージョンでデプロイ
EOF
}

# 継続的な検証を実行（バックグラウンド）
start_verification() {
    local total_requests=50
    local interval=0.2
    local result_file=$(mktemp)
    
    log_info "検証モード: ${total_requests}回のリクエストを送信します（間隔: ${interval}秒）"
    
    (
        local success=0
        local error=0
        
        for i in $(seq 1 $total_requests); do
            http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null)
            
            if [ "$http_code" = "200" ]; then
                success=$((success + 1))
                echo "OK" >> "$result_file"
            else
                error=$((error + 1))
                echo "ERROR" >> "$result_file"
            fi
            
            sleep $interval
        done
        
        # 結果をファイルに保存
        echo "$success|$error" > "${result_file}.summary"
    ) &
    
    VERIFY_PID=$!
    echo "$result_file"
}

# 検証結果を表示
show_verification_results() {
    local result_file=$1
    
    if [ -f "${result_file}.summary" ]; then
        IFS='|' read -r success error < "${result_file}.summary"
        
        echo ""
        log_info "=== 検証結果 ==="
        log_success "成功: $success"
        
        if [ "$error" -eq 0 ]; then
            log_success "エラー: $error ✅"
            log_success "🎉 完璧！ ダウンタイムなしでデプロイが完了しました"
        else
            log_warning "エラー: $error ⚠️"
            local error_rate=$(awk "BEGIN {printf \"%.2f\", ($error/($success+$error))*100}")
            log_warning "エラー率: ${error_rate}%"
        fi
        
        rm -f "$result_file" "${result_file}.summary"
    fi
}

# 引数解析
COMMAND="deploy"
VERSION=""
VERIFY_MODE=false

# 最初の引数がコマンドかチェック
if [[ $# -gt 0 ]] && [[ "$1" == "rollback" || "$1" == "deploy" ]]; then
    COMMAND=$1
    shift
fi

# rollbackコマンドの場合は即座に実行
if [ "$COMMAND" = "rollback" ]; then
    rollback "手動ロールバック"
    exit 0
fi

# deploy コマンドの引数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --verify)
            VERIFY_MODE=true
            shift
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION=$1
            else
                log_error "不明な引数: $1"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# バージョンのデフォルト値
if [ -z "$VERSION" ]; then
    VERSION=$(date +%Y%m%d-%H%M%S)
fi

export APP_VERSION=$VERSION

# メイン処理開始
log_info "=== Blue-Green Deployment ==="
log_info "デプロイバージョン: $VERSION"
echo ""

# 検証モードの開始
RESULT_FILE=""
if [ "$VERIFY_MODE" = true ]; then
    RESULT_FILE=$(start_verification)
    sleep 1
fi

# 現在のコンテナ数を取得
CURRENT_COUNT=$(docker compose ps -q app 2>/dev/null | wc -l | tr -d ' ')
log_info "現在のappコンテナ数: $CURRENT_COUNT"
echo ""

# Step 1: 新しいイメージをビルド
log_info "Step 1/5: 新しいイメージをビルド中..."
docker compose build app --quiet
log_success "ビルド完了"
echo ""

# Step 2: 新コンテナを起動（スケールアップ）
TARGET_SCALE=$((CURRENT_COUNT + 1))
log_info "Step 2/5: 新しいコンテナを起動中（スケール: ${CURRENT_COUNT} → ${TARGET_SCALE}）..."
docker compose up -d --no-deps --scale app=$TARGET_SCALE --no-recreate app 2>&1 | grep -v "^time="
log_success "新コンテナ起動完了"
echo ""

# Step 3: 新コンテナのヘルスチェック待機
log_info "Step 3/5: 新コンテナのヘルスチェック待機中..."
MAX_WAIT=30
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    HEALTHY_COUNT=$(docker compose ps app 2>/dev/null | grep -c "(healthy)" || echo 0)
    
    if [ "$HEALTHY_COUNT" -ge "$TARGET_SCALE" ]; then
        log_success "新コンテナが正常起動しました（healthy: $HEALTHY_COUNT）"
        break
    fi
    
    printf "."
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done
echo ""

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    log_error "タイムアウト: 新コンテナがhealthyになりませんでした"
    
    # 検証モードの終了
    if [ "$VERIFY_MODE" = true ] && [ -n "$VERIFY_PID" ]; then
        kill $VERIFY_PID 2>/dev/null || true
    fi
    
    # ロールバック実行
    rollback "ヘルスチェックタイムアウト"
    exit 1
fi
echo ""

# Step 4: 古いコンテナの停止（セッション終了待機）
log_info "Step 4/5: 古いコンテナのセッション終了待機中..."

# 全コンテナのIDを取得し、古いものから停止
ALL_CONTAINERS=$(docker compose ps -q app 2>/dev/null)
OLD_CONTAINERS=$(echo "$ALL_CONTAINERS" | head -n $CURRENT_COUNT)

# 古いコンテナの情報を保存（ロールバック用）
OLD_CONTAINER_IDS=""
OLD_IMAGE_IDS=""

for container_id in $OLD_CONTAINERS; do
    CONTAINER_NAME=$(docker inspect --format='{{.Name}}' $container_id 2>/dev/null | sed 's/\///')
    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' $container_id 2>/dev/null)
    
    log_info "セッション終了待機: $CONTAINER_NAME"
    
    # 進行中リクエストが0になるまで待機（最大60秒）
    SESSION_WAIT=0
    MAX_SESSION_WAIT=60
    
    while [ $SESSION_WAIT -lt $MAX_SESSION_WAIT ]; do
        # コンテナの/statsエンドポイントから進行中リクエスト数を取得
        ACTIVE_REQUESTS=$(docker exec $container_id wget -qO- http://localhost:8080/stats 2>/dev/null | grep -o '"active_requests":[0-9]*' | grep -o '[0-9]*' || echo "0")
        
        if [ "$ACTIVE_REQUESTS" -eq 0 ]; then
            log_success "セッション終了確認: $CONTAINER_NAME (active_requests=0)"
            break
        fi
        
        printf "  進行中リクエスト: %d\n" "$ACTIVE_REQUESTS"
        sleep 2
        SESSION_WAIT=$((SESSION_WAIT + 2))
    done
    
    if [ $SESSION_WAIT -ge $MAX_SESSION_WAIT ]; then
        log_warning "タイムアウト: $CONTAINER_NAME (強制停止)"
    fi
    
    # コンテナを停止するが削除はしない（ロールバック用に保持）
    log_info "停止中: $CONTAINER_NAME (イメージは保持)"
    docker stop $container_id >/dev/null 2>&1 || true
    
    OLD_CONTAINER_IDS="$OLD_CONTAINER_IDS $container_id"
    OLD_IMAGE_IDS="$OLD_IMAGE_IDS $OLD_IMAGE_ID"
done

log_success "古いコンテナ停止完了（ロールバック可能な状態）"
echo ""

# Step 5: スケールを調整（必要に応じて）
FINAL_SCALE=$CURRENT_COUNT
if [ $FINAL_SCALE -ne $CURRENT_COUNT ]; then
    log_info "Step 5/5: スケールを${FINAL_SCALE}に調整中..."
    docker compose up -d --no-deps --scale app=$FINAL_SCALE app 2>&1 | grep -v "^time="
    log_success "スケール調整完了"
else
    log_info "Step 5/5: スケール調整は不要です"
fi
echo ""

# 最終確認
log_info "=== デプロイ完了 ==="
log_info "現在稼働中のコンテナ:"
docker compose ps app 2>&1 | grep -v "^time="
echo ""

log_success "✅ Blue-Greenデプロイが正常に完了しました"
log_info "アプリケーション: http://localhost"
log_info "Haproxy統計: http://localhost:8404/stats"

# 検証モードの結果表示
if [ "$VERIFY_MODE" = true ]; then
    if [ -n "$VERIFY_PID" ]; then
        log_info "検証完了を待機中..."
        wait $VERIFY_PID 2>/dev/null || true
    fi
    
    if [ -n "$RESULT_FILE" ]; then
        show_verification_results "$RESULT_FILE"
    fi
fi

# 新コンテナの安定稼働確認
echo ""
log_info "=== 新バージョンの安定稼働確認 ==="
log_info "30秒間、新バージョンの動作を監視します..."
log_info "問題があれば Ctrl+C で中断してロールバックしてください"

STABILITY_CHECK=0
STABILITY_DURATION=30

while [ $STABILITY_CHECK -lt $STABILITY_DURATION ]; do
    # 新コンテナの状態確認
    NEW_CONTAINERS=$(docker compose ps -q app 2>/dev/null)
    HEALTHY_COUNT=$(docker compose ps app 2>/dev/null | grep -c "(healthy)" || echo 0)
    
    if [ "$HEALTHY_COUNT" -lt 1 ]; then
        log_error "新コンテナが異常終了しました"
        log_warning "ロールバックが必要です: ./deploy.sh rollback"
        exit 1
    fi
    
    printf "."
    sleep 1
    STABILITY_CHECK=$((STABILITY_CHECK + 1))
done
echo ""

log_success "新バージョンが安定稼働しています"

# 古いコンテナとイメージの削除
if [ -n "$OLD_CONTAINER_IDS" ]; then
    echo ""
    log_info "=== 古いコンテナとイメージの削除 ==="
    
    for container_id in $OLD_CONTAINER_IDS; do
        CONTAINER_NAME=$(docker inspect --format='{{.Name}}' $container_id 2>/dev/null | sed 's/\///' || echo "unknown")
        if [ "$CONTAINER_NAME" != "unknown" ]; then
            log_info "削除中: $CONTAINER_NAME"
            docker rm $container_id >/dev/null 2>&1 || true
        fi
    done
    
    # 古いイメージの削除（使用されていないイメージのみ）
    for image_id in $OLD_IMAGE_IDS; do
        # イメージが他のコンテナで使用されていないか確認
        IMAGE_IN_USE=$(docker ps -a --filter "ancestor=$image_id" -q | wc -l | tr -d ' ')
        
        if [ "$IMAGE_IN_USE" -eq 0 ]; then
            IMAGE_TAG=$(docker inspect --format='{{range .RepoTags}}{{.}} {{end}}' $image_id 2>/dev/null || echo "")
            log_info "イメージ削除: $IMAGE_TAG"
            docker rmi $image_id >/dev/null 2>&1 || true
        else
            log_info "イメージは他のコンテナで使用中のため保持します"
        fi
    done
    
    log_success "クリーンアップ完了"
fi
