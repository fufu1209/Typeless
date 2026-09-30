#!/usr/bin/env bash
#
# 创建一把**稳定的**自签名代码签名证书，供 build-app.sh 使用。
#
# ── 为什么需要它 ───────────────────────────────────────────────────────────
# app 原来用 ad-hoc 签名（`codesign --force --deep --sign -`），指纹每次构建都变。
# 而钥匙串条目的授权记录的是「创建它的那个 app 的签名指纹」——
# 于是每次重装 app，GUI 与守护都会卡在
#   「Typeless Switchboard 想要使用你储存在钥匙串的 "local.typeless.switchboard"
#     中的机密信息」
# 这个授权框上：不点它，两个进程就永远停在 SecItemCopyMatching，GUI 窗口不出、
# 守护日志不写（2026-09-30 实测）。
#
# 换成固定证书后，app 的指定要求（designated requirement）从
# 「cdhash H"…"」变成「identifier + certificate leaf H"…"」，跨构建稳定 ——
# 授权框不再重复出现。顺带也让「安装窗口期签名校验失败」这类问题绝迹。
#
# 只需要跑一次。之后 build-app.sh 会自动检测并使用这把身份。
#
# ── 用法 ───────────────────────────────────────────────────────────────────
#   ./scripts/create-signing-identity.sh              # 用默认名字
#   ./scripts/create-signing-identity.sh "My Cert"    # 自定义名字
#   KEYCHAIN=/path/to/x.keychain-db ./scripts/create-signing-identity.sh
#
# 退出码：0 = 身份已就绪（含本来就存在）；1 = 创建失败

set -euo pipefail

NAME="${1:-TypelessSwitchboard Local}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "找不到 openssl，无法创建证书。" >&2
  exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "已存在签名身份「$NAME」，无需重建："
  security find-identity -v -p codesigning | grep -F "$NAME" || true
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 只申请 codeSigning 用途，且不是 CA —— 越小越好，避免被当成可信根。
cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "① 生成自签名证书与私钥（有效期 10 年）…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1

echo "② 打包成 PKCS#12…"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass: -name "$NAME" >/dev/null 2>&1

echo "③ 导入登录钥匙串…"
# -A：允许应用免提示使用这把私钥（本机自用，且这把证书只用于给本工具签名）。
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" -A \
  -T /usr/bin/codesign -T /usr/bin/security

# ④ 分区列表：让 codesign 无需交互即可取用私钥。
#    失败不致命（-A 通常已经够），所以吞掉错误且不等待输入。
echo "④ 设置私钥分区列表…"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" \
  </dev/null >/dev/null 2>&1 \
  || echo "   （跳过。若 build-app.sh 签名时弹一次授权框，点「始终允许」即可，之后不再弹）"

echo
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$NAME"; then
  echo "完成。可用身份："
  security find-identity -v -p codesigning | grep -F "$NAME" || true
  echo
  echo "下一步：./scripts/build-app.sh --install --launch（会自动用它签名）"
else
  echo "创建后仍未在钥匙串里找到该身份，请检查钥匙串是否被锁定。" >&2
  exit 1
fi
