# Blue-Green Deployment with HAProxy

HAProxyを使用したゼロダウンタイムのBlue-Greenデプロイメントのシンプルな実装例

## 特徴

- **最小限の依存関係**: HAProxy（軽量リバースプロキシ）のみ
- **ゼロダウンタイム**: 新旧コンテナの段階的な入れ替え
- **シンプルな構成**: 1つのスクリプトで完結
- **本番実績のある技術スタック**: 広く使われている実証済みのパターン

## プロジェクト構成

```text
blue-green-demo/
├── app/
│   ├── main.go           # Go標準ライブラリのみで実装したWebアプリ
│   └── Dockerfile        # マルチステージビルド
├── haproxy/
│   └── haproxy.cfg       # HAProxy設定
├── compose.yml           # Docker Compose設定
├── deploy.sh             # デプロイスクリプト
└── README.md             # このファイル
```

## クイックスタート

### 1. 初回起動

```bash
# プロジェクトディレクトリに移動
cd blue-green-demo

# コンテナを起動
docker compose up -d --build
```

### 2. 動作確認

```bash
# アプリケーションにアクセス
curl http://localhost/

# 出力例:
# {
#   "version": "1.0.0",
#   "hostname": "abc123def456",
#   "container_id": "abc123def456",
#   "timestamp": "2024-01-01T00:00:00Z",
#   "uptime": "30s",
#   "total_requests": 1,
#   "message": "Hello from container abc123def456 (version 1.0.0)"
# }

# ヘルスチェック
curl http://localhost/health

# HAProxy統計画面をブラウザで開く
open http://localhost:8404/stats
```

### 3. Blue-Greenデプロイの実行

#### 通常のデプロイ

```bash
./deploy.sh 2.0.0
```

#### 検証付きデプロイ（推奨）

デプロイ中に継続的にリクエストを送信してダウンタイムを検証します：

```bash
./deploy.sh 2.0.0 --verify
```

出力例

```text
=== Blue-Green Deployment ===
デプロイバージョン: 2.0.0

検証モード: 50回のリクエストを送信します（間隔: 0.2秒）
現在のappコンテナ数: 1

Step 1/5: 新しいイメージをビルド中...
ビルド完了

Step 2/5: 新しいコンテナを起動中（スケール: 1 → 2）...
新コンテナ起動完了

Step 3/5: 新コンテナのヘルスチェック待機中...
新コンテナが正常起動しました（healthy: 2）

Step 4/5: 古いコンテナを削除中...
停止中: blue-green-demo-app-1
古いコンテナ削除完了

Step 5/5: スケール調整は不要です

=== デプロイ完了 ===

=== 検証結果 ===
成功: 50
エラー: 0 ✅
🎉 完璧！ ダウンタイムなしでデプロイが完了しました
```

## デプロイの仕組み

### Blue-Greenデプロイのフロー

```text
1. 初期状態: 1コンテナ稼働中
   [app-1 (v1.0)] ← HAProxy

2. スケールアップ: 新コンテナ起動
   [app-1 (v1.0)] ← HAProxy → [app-2 (v2.0)]
   
3. ヘルスチェック: 新コンテナの準備完了を待機
   [app-1 (v1.0)] ← HAProxy ← [app-2 (v2.0)] ✅
   
4. 古いコンテナ削除: トラフィックを新コンテナのみに
   [app-2 (v2.0)] ← HAProxy
```

### 従来の方法との比較

- ❌ 従来の方法（ダウンタイムあり）

```bash
docker compose down    # ← サービス停止
docker compose up -d   # ← 再起動までダウンタイム
```

- ✅ Blue-Green方式（ゼロダウンタイム）

```bash
./deploy.sh 2.0.0      # ← サービスは停止しない
```

## アプリケーション仕様

### エンドポイント

- `GET /` - アプリケーション情報（バージョン、コンテナID、統計など）
- `GET /health` - ヘルスチェック（HAProxyが使用）
- `GET /ready` - Readinessチェック
- `GET /stats` - 統計情報

### 技術スタック

- **言語**: Go（標準ライブラリのみ）
- **コンテナ**: Docker + Docker Compose
- **ロードバランサー**: HAProxy 2.8
- **ベースイメージ**: Alpine Linux（最小構成）

## HAProxy設定

### 主要機能

- **ラウンドロビンロードバランシング**: 複数コンテナへの負荷分散
- **自動ヘルスチェック**: 10秒間隔で`/health`エンドポイントを監視
- **Docker DNS連携**: コンテナの自動検出
- **統計情報**: リアルタイムの監視ダッシュボード

### 統計画面

<http://localhost:8404/stats> で以下の情報を確認可能です

- 各コンテナの状態（UP/DOWN）
- リクエスト数
- レスポンスタイム
- エラー率

## スクリプトの使い方

### deploy.sh

```bash
使用方法: ./deploy.sh [VERSION] [OPTIONS]

引数:
  VERSION               デプロイするバージョン番号（省略時は日時を使用）

オプション:
  --verify             デプロイ中に継続的なリクエストを送信して検証
  -h, --help           このヘルプを表示

例:
  ./deploy.sh 2.0.0                    # バージョン2.0.0にデプロイ
  ./deploy.sh 2.0.0 --verify           # 検証しながらデプロイ
  ./deploy.sh                          # タイムスタンプバージョンでデプロイ
```

## トラブルシューティング

### ポート80が既に使用されている

```bash
# 使用中のプロセスを確認
lsof -i :80

# compose.ymlのポートを変更
# ports:
#   - "8080:80"  # 80 → 8080に変更
```

### コンテナがhealthyにならない

```bash
# ログを確認
docker compose logs app

# ヘルスチェック状態を確認
docker compose ps

# 個別コンテナの詳細を確認
docker inspect <container_id> | grep -A 10 Health
```

### HAProxyが起動しない

```bash
# HAProxy設定をテスト
docker run --rm -v $(pwd)/haproxy/haproxy.cfg:/test.cfg \
    haproxy:2.8-alpine haproxy -c -f /test.cfg

# HAProxyのログを確認
docker compose logs haproxy
```

### デプロイがタイムアウトする

新コンテナのヘルスチェックが30秒以内に完了しない場合、タイムアウトします

以下を確認してください

1. アプリケーションが正常に起動しているか
2. `/health`エンドポイントが正しく応答しているか
3. ネットワーク設定が正しいか

## クリーンアップ

```bash
# 全コンテナを停止・削除
docker compose down

# イメージも削除
docker compose down --rmi all

# ボリュームも削除（完全クリーンアップ）
docker compose down -v --rmi all
```

## カスタマイズ

### コンテナ数の変更

デフォルトは1コンテナですが、高可用性が必要な場合は増やせます

```yaml
# compose.yml
deploy:
  replicas: 2  # 2コンテナで常時稼働
```

この場合、デプロイ時は 2→3→2 のフローになります

### ヘルスチェック間隔の調整

```yaml
# compose.yml
healthcheck:
  interval: 5s   # 5秒間隔に短縮
  timeout: 3s
  retries: 2
```

### HAProxyのタイムアウト設定

```text
# haproxy/haproxy.cfg
defaults
  timeout connect 10s
  timeout client  60s
  timeout server  60s
```

## 本番環境への適用

### 推奨事項

1. **環境変数の外部化**: `.env`ファイルで設定を管理
2. **シークレット管理**: Docker SecretsまたはVaultを使用
3. **監視の強化**: Prometheus + Grafanaの導入
4. **ログ集約**: FluentdやELKスタックの導入
5. **SSL/TLS**: Let's Encryptの統合
6. **リソース制限**: CPU/メモリ制限の設定
7. **自動スケーリング**: トラフィックに応じた自動スケール

### セキュリティ考慮事項

- 非rootユーザーでアプリケーション実行
- 最小限のベースイメージ（Alpine）使用
- 定期的なセキュリティアップデート
- ネットワークセグメンテーション
- アクセスログの監視

## アーキテクチャの利点

### 1. シンプルさ

- HAProxyのみの依存関係
- 外部サービス不要
- 理解しやすい設定

### 2. 信頼性

- 実証済みの技術スタック
- 本番環境での実績
- ロールバックが容易

### 3. パフォーマンス

- 軽量なHAProxy
- 効率的なロードバランシング
- 低レイテンシ

### 4. 運用性

- 自動ヘルスチェック
- リアルタイム監視
- 簡単なデバッグ

## ライセンス

MIT License
