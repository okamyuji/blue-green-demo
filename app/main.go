package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sync/atomic"
	"time"
)

// アプリケーションのバージョン（ビルド時に環境変数で設定可能）
var version = getEnv("APP_VERSION", "1.0.0")

// リクエストカウンター（アトミック操作で安全にインクリメント）
var requestCounter uint64

// 進行中リクエスト数（セッション管理用）
var activeRequests int64

// アプリケーション起動時刻
var startTime = time.Now()

// 環境変数取得ヘルパー関数
func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// レスポンスデータ構造
type Response struct {
	Version     string    `json:"version"`
	Hostname    string    `json:"hostname"`
	ContainerID string    `json:"container_id"`
	Timestamp   time.Time `json:"timestamp"`
	Uptime      string    `json:"uptime"`
	Requests    uint64    `json:"total_requests"`
	Message     string    `json:"message"`
}

// ヘルスチェックエンドポイント
func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	response := map[string]string{
		"status":  "healthy",
		"version": version,
	}

	json.NewEncoder(w).Encode(response)
}

// メインエンドポイント
func rootHandler(w http.ResponseWriter, r *http.Request) {
	// 進行中リクエスト数をインクリメント
	atomic.AddInt64(&activeRequests, 1)
	defer atomic.AddInt64(&activeRequests, -1)

	// リクエストカウンターをインクリメント
	count := atomic.AddUint64(&requestCounter, 1)

	// ランダム遅延（1秒〜5秒）でセッション状態をシミュレート
	delayMs := rand.Intn(4000) + 1000
	time.Sleep(time.Duration(delayMs) * time.Millisecond)

	// ホスト名取得
	hostname, err := os.Hostname()
	if err != nil {
		hostname = "unknown"
	}

	// コンテナID取得（短縮版）
	containerID := hostname
	if len(hostname) > 12 {
		containerID = hostname[:12]
	}

	// アップタイム計算
	uptime := time.Since(startTime).Round(time.Second)

	response := Response{
		Version:     version,
		Hostname:    hostname,
		ContainerID: containerID,
		Timestamp:   time.Now(),
		Uptime:      uptime.String(),
		Requests:    count,
		Message:     fmt.Sprintf("Hello from container %s (version %s) - delayed %dms", containerID, version, delayMs),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)

	// アクセスログ
	log.Printf("[%s] %s %s - Request #%d (delayed %dms)", containerID, r.Method, r.URL.Path, count, delayMs)
}

// Readinessチェック（起動後一定時間経過したら準備完了とみなす）
func readyHandler(w http.ResponseWriter, r *http.Request) {
	// 起動後5秒経過していれば準備完了
	if time.Since(startTime) < 5*time.Second {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{
			"status": "not ready",
			"reason": "warming up",
		})
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ready",
	})
}

// 統計情報エンドポイント
func statsHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()

	stats := map[string]interface{}{
		"version":         version,
		"hostname":        hostname,
		"uptime":          time.Since(startTime).Round(time.Second).String(),
		"total_requests":  atomic.LoadUint64(&requestCounter),
		"active_requests": atomic.LoadInt64(&activeRequests),
		"started_at":      startTime.Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

func main() {
	// 乱数シード初期化
	rand.Seed(time.Now().UnixNano())

	port := getEnv("PORT", "8080")

	// ルーティング設定
	http.HandleFunc("/", rootHandler)
	http.HandleFunc("/health", healthHandler)
	http.HandleFunc("/ready", readyHandler)
	http.HandleFunc("/stats", statsHandler)

	// サーバー起動メッセージ
	hostname, _ := os.Hostname()
	log.Printf("🚀 Starting server version %s", version)
	log.Printf("📦 Container: %s", hostname)
	log.Printf("🌐 Listening on port %s", port)
	log.Printf("✅ Health check: http://localhost:%s/health", port)
	log.Printf("📊 Stats: http://localhost:%s/stats", port)

	// HTTPサーバー起動
	addr := fmt.Sprintf(":%s", port)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatal(err)
	}
}
