# The broker image: Atlantis, plus the pieces that make its gate ours.
#
# Atlantis is the applier and is adopted rather than written. What this image
# adds is the rule sets it evaluates, the cost gate it runs as a workflow step,
# and OpenTofu in place of Terraform.
#
# Pinned by digest, not tag. A refused apply is signalled by an internal
# Atlantis message rather than a stable error code, so the harness client
# matches those strings and a version change can silently turn a refusal into a
# success. The contract test asserts them against this version; bumping this
# digest means re-running it.
ARG ATLANTIS_IMAGE=ghcr.io/runatlantis/atlantis:v0.48.1
FROM ${ATLANTIS_IMAGE}

ARG CONFTEST_VERSION=0.71.1
ARG TOFU_VERSION=1.13.1
ARG TARGETARCH=amd64

USER root

# conftest evaluates the rule sets; OpenTofu replaces Terraform so the runtime
# stays MPL-2.0 rather than BUSL-1.1.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) CONFTEST_ARCH=x86_64; TOFU_ARCH=amd64 ;; \
      arm64) CONFTEST_ARCH=arm64;  TOFU_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    apk add --no-cache --virtual .fetch curl unzip; \
    curl -fsSL -o /tmp/conftest.tgz \
      "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${CONFTEST_ARCH}.tar.gz"; \
    tar -xzf /tmp/conftest.tgz -C /usr/local/bin conftest; \
    chmod 0755 /usr/local/bin/conftest; \
    curl -fsSL -o /tmp/tofu.zip \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TOFU_ARCH}.zip"; \
    unzip -q -o /tmp/tofu.zip -d /usr/local/bin tofu; \
    chmod 0755 /usr/local/bin/tofu; \
    rm -f /tmp/conftest.tgz /tmp/tofu.zip; \
    apk del .fetch; \
    conftest --version; \
    tofu version

# Python for the cost gate. It is a workflow step rather than a rego rule
# because conftest sees the plan and Atlantis has no cost concept.
RUN apk add --no-cache python3 py3-pip

# The rule sets are read-only to the Atlantis user: a plan under change must
# never be able to rewrite the rules that judge it.
COPY --chown=root:root policies/ /etc/osf/policies/
COPY --chown=root:root agent_iac_broker/ /opt/osf/agent_iac_broker/
COPY --chown=root:root pyproject.toml README.md LICENSE /opt/osf/

RUN set -eux; \
    chmod -R 0555 /etc/osf/policies; \
    pip install --no-cache-dir --break-system-packages /opt/osf; \
    agent-iac-cost-gate --help > /dev/null

# Verify the rule sets are well formed at build time, so a broken policy fails
# the image rather than the first production plan.
RUN conftest verify --policy /etc/osf/policies

USER atlantis
