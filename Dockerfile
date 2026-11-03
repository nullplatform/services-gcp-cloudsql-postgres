# syntax=docker/dockerfile:1
# Worker image: the bridge runs the entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.7

# OpenTofu, pinned, so no action downloads it at runtime. Keep TOFU_VERSION in
# sync with .github/workflows/terraform.yml and with scripts/do_tofu's fallback.
ARG TOFU_VERSION=1.13.2
# The tarballs' SHA-256, from the release's tofu_<version>_SHA256SUMS. Pinned
# here rather than fetched with the tarball, so a tampered release fails the
# build. Update both with TOFU_VERSION.
ARG TOFU_SHA256_AMD64=ac05d9952662c7db28dd57e93f0a68018837bfdf9342384ec0987977c16a9645
ARG TOFU_SHA256_ARM64=88e2d9e3f94f97b76ab2faf55ade87578f56aed19c5e45fa139d70e994366d1f
# TARGETARCH is a BuildKit built-in and is empty under the legacy builder.
ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64|amd64)  arch=amd64 ;; \
        aarch64|arm64) arch=arm64 ;; \
        *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "$arch" in \
      amd64) sha="$TOFU_SHA256_AMD64" ;; \
      arm64) sha="$TOFU_SHA256_ARM64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/tofu.tar.gz \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.tar.gz"; \
    echo "${sha}  /tmp/tofu.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/tofu.tar.gz -C /usr/local/bin tofu; \
    rm -f /tmp/tofu.tar.gz; \
    tofu version

# --chown: np chmods the action script in place, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=gcp-cloud-sql-postgresql \
    NP_SERVICE_PATH=/app/pkg/cloud-sql-postgresql \
    NP_SCOPE_ENTRYPOINT=/app/pkg/cloud-sql-postgresql/entrypoint/entrypoint

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
