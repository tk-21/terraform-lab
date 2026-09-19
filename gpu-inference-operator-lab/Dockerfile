# マルチステージビルド: ビルダーとランタイムを分離してイメージサイズを最小化する
#
# arm64のみビルドする理由:
#   全インフラをGraviton2(arm64/g5g系)で統一しているため、x86イメージは不要。
#   クロスアーキビルドを複数維持するとCI時間・ECRストレージコスト・テスト対象が増加する。
#   Go自体がクロスコンパイル対応なので --platform linux/arm64 を指定するだけでよい。

FROM golang:1.22-alpine AS builder

WORKDIR /workspace

# 依存解決を先にキャッシュする (ソースより変更頻度が低い)
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO無効でスタティックバイナリをビルドする (distrolessベースイメージ向け)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
    -a \
    -ldflags='-extldflags "-static"' \
    -o manager main.go

# distroless: シェルもパッケージマネージャも含まないため攻撃面を最小化できる
# nonrootバリアントでUID 65532(nonroot)として実行する
FROM gcr.io/distroless/static:nonroot

WORKDIR /

COPY --from=builder /workspace/manager .

# nonrootユーザーで動かすことでコンテナエスケープリスクを低減する
USER 65532:65532

ENTRYPOINT ["/manager"]
