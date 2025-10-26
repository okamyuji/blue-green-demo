# ビルドステージ
FROM golang:1.21-alpine AS builder

WORKDIR /build

# ソースコードをコピー
COPY main.go .

# バイナリをビルド（静的リンク）
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -ldflags="-w -s" -o app main.go

# 実行ステージ（最小限のイメージ）
FROM alpine:latest

# セキュリティアップデートとca-certificatesをインストール
RUN apk --no-cache add ca-certificates curl

WORKDIR /app

# ビルドステージからバイナリをコピー
COPY --from=builder /build/app .

# 非rootユーザーで実行
RUN adduser -D -u 1000 appuser && \
    chown -R appuser:appuser /app

USER appuser

# ポート公開
EXPOSE 8080

# ヘルスチェック設定
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# アプリケーション起動
CMD ["./app"]
