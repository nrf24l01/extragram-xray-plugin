FROM debian:bookworm-slim

ARG GO_VERSION=1.24.4
ARG NDK_VERSION=r27c
ARG XRAY_VERSION=v1.8.24

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_NDK_HOME=/opt/android-ndk
ENV PATH=/usr/local/go/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        clang \
        curl \
        git \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

RUN case "$(dpkg --print-architecture)" in \
        amd64) GO_ARCH=amd64 ;; \
        arm64) GO_ARCH=arm64 ;; \
        *) echo "unsupported build host arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz

RUN curl -fsSL "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" -o /tmp/ndk.zip \
    && unzip -q /tmp/ndk.zip -d /opt \
    && mv "/opt/android-ndk-${NDK_VERSION}" "${ANDROID_NDK_HOME}" \
    && rm /tmp/ndk.zip

WORKDIR /build

RUN git clone --depth 1 --branch "${XRAY_VERSION}" https://github.com/XTLS/Xray-core.git xray-core || \
    (git clone --depth 1 https://github.com/XTLS/Xray-core.git xray-core \
     && cd xray-core \
     && git fetch --depth 1 origin "${XRAY_VERSION}" \
     && git checkout FETCH_HEAD)

WORKDIR /build/wrapper

RUN cat > go.mod <<'EOF'
module local/libxray

go 1.24

require github.com/xtls/xray-core v1.8.24

replace github.com/xtls/xray-core => ../xray-core
EOF

RUN cat > libxray.go <<'EOF'
package main

/*
#include <stdlib.h>
*/
import "C"

import (
    "sync"
    "unsafe"

    "github.com/xtls/xray-core/core"
    _ "github.com/xtls/xray-core/main/distro/all"
)

var (
    mu       sync.Mutex
    instance *core.Instance
)

func cstr(s string) *C.char {
    if s == "" {
        return nil
    }
    return C.CString(s)
}

//export StartCore
func StartCore(config *C.char) *C.char {
    mu.Lock()
    defer mu.Unlock()

    if config == nil {
        return cstr("empty config")
    }

    if instance != nil {
        instance.Close()
        instance = nil
    }

    cfg := C.GoString(config)
    inst, err := core.StartInstance("json", []byte(cfg))
    if err != nil {
        return cstr(err.Error())
    }

    instance = inst
    return nil
}

//export StopCore
func StopCore() {
    mu.Lock()
    defer mu.Unlock()

    if instance != nil {
        instance.Close()
        instance = nil
    }
}

//export FreeCString
func FreeCString(p *C.char) {
    if p != nil {
        C.free(unsafe.Pointer(p))
    }
}

func main() {}
EOF

RUN go mod tidy

RUN mkdir -p /out/arm64-v8a \
    && CC="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang" \
       CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
       go build -trimpath -buildmode=c-shared -ldflags='-s -w' -o /out/arm64-v8a/libxray.so . \
    && sha256sum /out/arm64-v8a/libxray.so > /out/arm64-v8a/libxray.so.sha256

CMD ["/bin/sh", "-lc", "ls -lh /out/arm64-v8a && cat /out/arm64-v8a/libxray.so.sha256"]
