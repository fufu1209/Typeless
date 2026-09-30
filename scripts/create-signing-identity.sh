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
#   ad-hoc:  cdhash H"…"                      ← 每次构建都变
#   证书:    identifier "…" and certificate leaf H"…"   ← 跨构建稳定
# 于是授权框不再重复出现。顺带也让「安装窗口期签名校验失败」这类问题绝迹。
#
# ⚠️ 换成证书身份后**还会再弹一次**授权框（旧条目里记的是老的 ad-hoc 指纹）。
#    那一次点「始终允许」，之后就不会再弹了 —— 因为要求从此固定。
#
# 只需要跑一次。之后 build-app.sh 会自动检测并使用这把身份。
#
# ── 用法 ───────────────────────────────────────────────────────────────────
#   ./scripts/create-signing-identity.sh              # 用默认名字
#   ./scripts/create-signing-identity.sh "My Cert"    # 自定义名字
#   KEYCHAIN=/path/to/x.keychain-db ./scripts/create-signing-identity.sh
#
# 退出码：0 = 身份已就绪（含本来就存在）；1 = 创建失败
#
# ── 实现注记（踩过的坑，别改回去）─────────────────────────────────────────
# 1. **不要用 PKCS#12**。OpenSSL 3.x 默认用 SHA-256 MAC + AES PBE 导出 p12，
#    超出 macOS `security` 的解析能力，会报
#    「MAC verification failed during PKCS12 import (wrong password?)」。
#    加 `-macalg sha1` 也不够（本机 OpenSSL 3.6.4 实测仍失败）。
#    证书与私钥**分别以 PEM 导入**没有这个问题，而且不需要钥匙串密码。
# 2. **不要用 find-identity -v 做检测**。自签名证书不受信任，`-v` 只列
#    「有效」身份 ⇒ 永远返回 0。用 `security find-certificate -c "<CN>"` 判断。
# 3. 导入时加 `-A`（允许任意应用使用该私钥）就不必再设 `set-key-partition-list`，
#    因此整个流程**无需输入任何密码**。

set -euo pipefail

NAME="${1:-TypelessSwitchboard Local}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "找不到 openssl，无法创建证书。" >&2
  exit 1
fi

# 自签名证书不受信任，find-identity -v 看不到它 —— 必须用 find-certificate。
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "已存在签名身份「${NAME}」，无需重建。"
  echo "（自签名证书不受信任，find-identity -v 看不到它是正常的，不影响签名。）"
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

# ② 证书与私钥分别以 PEM 导入（不要走 PKCS#12，见文件头注记 1）。
#    -A：允许任意应用使用该私钥，于是不必再设分区列表、不必输密码。
echo "② 导入证书与私钥到钥匙串（-A：免授权提示）…"
security import "$WORK/cert.pem" -k "$KEYCHAIN" -A
security import "$WORK/key.pem"  -k "$KEYCHAIN" -A

echo
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "完成。证书已入库："
  security find-certificate -c "$NAME" 2>/dev/null | grep -E '"labl"|"alis"' | sed 's/^/   /' || true
  echo
  echo "说明：这是自签名证书，**不受系统信任**（find-identity -v 会显示 0 个），"
  echo "      但 codesign 照常能用，且签名后的指定要求跨构建稳定 —— 这正是我们要的。"
  echo
  echo "下一步：./scripts/build-app.sh --install --launch（会自动用它签名）"
  echo "       装完第一次启动若还弹一次钥匙串授权框，点「始终允许」即可，之后不再弹。"
  echo
  echo "想删掉这把身份：security delete-certificate -c \"$NAME\""
else
  echo "导入后仍未在钥匙串里找到该证书，请检查钥匙串是否被锁定。" >&2
  exit 1
fi
