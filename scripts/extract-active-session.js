const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');
const https = require('https');

function looksLikeDeviceUserLimit(text) {
  if (!text) return false;
  const lower = String(text).toLowerCase();
  const spaced = lower.replace(/\s+/g, ' ');
  const compact = lower.replace(/\s+/g, '');
  return (
    spaced.includes('number of users logged into this device has exceeded the limit') ||
    spaced.includes('users logged into this device has exceeded') ||
    spaced.includes('device has exceeded the limit') ||
    spaced.includes('device user limit') ||
    spaced.includes('too many users on this device') ||
    compact.includes('numberofusersloggedintothisdevicehasexceededthelimit') ||
    compact.includes('usersloggedintothisdevicehasexceeded') ||
    compact.includes('devicehasexceededthelimit') ||
    compact.includes('deviceuserlimit') ||
    compact.includes('toomanyusersonthisdevice') ||
    spaced.includes('登录该设备的用户数已超过限制') ||
    spaced.includes('设备登录用户数已超') ||
    spaced.includes('设备用户数超限') ||
    spaced.includes('此设备登录的用户数已超过限制')
  );
}

function summarizeApiError(statusCode, bodyText) {
  const compact = String(bodyText || '').replace(/\s+/g, ' ').trim().slice(0, 400);
  let message = '';
  try {
    const parsed = JSON.parse(bodyText || '{}');
    message = parsed.message || parsed.error || parsed.detail || parsed.msg || '';
    if (!message && parsed.data && typeof parsed.data === 'object') {
      message = parsed.data.message || parsed.data.error || '';
    }
  } catch (_) {}
  const combined = [message, compact].filter(Boolean).join(' | ');
  if (looksLikeDeviceUserLimit(combined) || looksLikeDeviceUserLimit(bodyText)) {
    return {
      code: 'DEVICE_USER_LIMIT',
      error: `设备登录用户数已超限 (HTTP ${statusCode}): ${combined || 'The number of users logged into this device has exceeded the limit.'}`
    };
  }
  return {
    code: statusCode === 200 ? 'API_PAYLOAD_MISMATCH' : 'API_HTTP_ERROR',
    error: statusCode === 200
      ? (combined ? `API 返回格式不匹配：${combined}` : 'API 返回格式不匹配')
      : `API 额度拉取失败 (HTTP ${statusCode})${combined ? ': ' + combined : ''}`
  };
}

function getActiveSession() {
  return new Promise((resolve) => {
    try {
      const platform = os.platform();
      const arch = os.arch();
      const appName = 'Typeless';

      const sha256Hex = crypto.createHash('sha256').update(platform + '-' + arch).digest('hex');
      const pbkdf2Key = crypto.pbkdf2Sync(sha256Hex + appName, 'typeless-user-service', 10000, 32, 'sha256');

      const userdataPath = path.join(process.env.HOME, 'Library/Application Support/Typeless/user-data.json');
      if (!fs.existsSync(userdataPath)) {
        return resolve({ success: false, error: "未检测到 Typeless 客户端的登录缓存文件" });
      }

      const data = fs.readFileSync(userdataPath);
      if (data.length < 17 || data[16] !== 0x3a) {
        return resolve({ success: false, error: "登录缓存文件格式不正确或已损坏" });
      }

      const iv = data.slice(0, 16);
      const ciphertext = data.slice(17);
      const derivedPassword = crypto.pbkdf2Sync(pbkdf2Key, iv.toString(), 10000, 32, 'sha512');

      let credentials;
      let rawJsonString = "";
      try {
        const decipher = crypto.createDecipheriv('aes-256-cbc', derivedPassword, iv);
        let dec = decipher.update(ciphertext);
        dec = Buffer.concat([dec, decipher.final()]);
        rawJsonString = dec.toString('utf8');
        const parsed = JSON.parse(rawJsonString);
        credentials = JSON.parse(parsed.userData);
      } catch (e) {
        return resolve({ success: false, error: "本地缓存解密失败，可能是指纹不匹配或客户端已退出" });
      }

      const { access_token, user_id, email } = credentials;
      if (!access_token || !user_id) {
        return resolve({ success: false, error: "登录缓存中未包含有效的授权 Token" });
      }

      // 获取额度使用状况
      const Qs = "7d4a8f2e6b9c3a1f5e8d2c7b4a9f6e3d1b5a2f9e6d3c0b7a4f1e8d5c2b9f6a3d";
      const yc = "9b1c67af3f7ecd1501d7da7196f281f5e0c7c292ebc2227d49ff9d20";

      const timestamp = Math.floor(Date.now() / 1000);
      const appVersion = "mac_2.0.0";
      const pathname = "/user/usage_stats";

      const signStr = `${timestamp}:${appVersion}:${pathname}:${user_id}`;
      const hmacKeyString = `${timestamp}:${yc}`;

      const hmac = crypto.createHmac('sha1', hmacKeyString).update(signStr).digest('hex');

      const aesKey = Buffer.from(Qs, 'hex');
      const ivAes = Buffer.alloc(16, 0);
      const cipher = crypto.createCipheriv('aes-256-cbc', aesKey, ivAes);
      let encrypted = cipher.update(hmac, 'utf8', 'base64');
      encrypted += cipher.final('base64');

      const options = {
        hostname: 'api.typeless.com',
        port: 443,
        path: pathname,
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${access_token}`,
          'X-Authorization': encrypted,
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Typeless/2.0.0 Chrome/120.0.6099.291 Electron/28.2.1 Safari/537.36',
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        timeout: 6000
      };

      const req = https.request(options, (res) => {
        let body = '';
        res.on('data', (chunk) => body += chunk);
        res.on('end', () => {
          if (res.statusCode !== 200) {
            const summarized = summarizeApiError(res.statusCode, body);
            return resolve({
              success: true,
              email: email,
              userId: user_id,
              rawJson: rawJsonString,
              errorCode: summarized.code,
              error: summarized.error
            });
          }
          try {
            const respObj = JSON.parse(body);
            if (respObj.status === 'OK' && respObj.data && respObj.data.voice_transcription) {
              const vt = respObj.data.voice_transcription;
              return resolve({
                success: true,
                email: email,
                userId: user_id,
                rawJson: rawJsonString,
                usedCharacters: vt.week_word_usage_value,
                monthlyLimit: vt.week_word_usage_limit,
                info: `总字数: ${vt.total_words}, 已用秒数: ${Math.round(vt.total_audio_seconds)}秒`
              });
            }
            const summarized = summarizeApiError(200, body);
            return resolve({
              success: true,
              email: email,
              userId: user_id,
              rawJson: rawJsonString,
              errorCode: summarized.code,
              error: summarized.error
            });
          } catch (e) {
            const summarized = summarizeApiError(200, body);
            return resolve({
              success: true,
              email: email,
              userId: user_id,
              rawJson: rawJsonString,
              errorCode: summarized.code,
              error: summarized.error || "解析 API 报文失败"
            });
          }
        });
      });

      req.on('error', (e) => {
        resolve({
          success: true,
          email: email,
          userId: user_id,
          rawJson: rawJsonString,
          error: `API 请求网络连接失败: ${e.message}`
        });
      });

      req.on('timeout', () => {
        req.destroy();
        resolve({
          success: true,
          email: email,
          userId: user_id,
          rawJson: rawJsonString,
          error: "API 请求连接超时"
        });
      });

      req.write(JSON.stringify({}));
      req.end();

    } catch (err) {
      resolve({ success: false, error: `提取过程异常: ${err.message}` });
    }
  });
}

getActiveSession().then(res => {
  console.log(JSON.stringify(res, null, 2));
});
