#!/bin/bash
# 兼容入口：保持对旧版脚本名称的支持
# 新逻辑已整合到 bbr-fq.sh 中，因此此脚本仅作为包装器

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/bbr-fq.sh" "$@"
