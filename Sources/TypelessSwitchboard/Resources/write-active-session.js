// Typeless Switchboard —— 把一份 userData JSON 写回 Typeless 本地会话缓存（静默换号用）
//
// 真正的加解密实现在 `extract-active-session.js`，这里只是薄包装。
// 以前这个文件的加解密逻辑是单独抄的一份，和读取端各改各的；
// 现在两边共用同一套派生逻辑，改一处即可。
//
// 用法（v2.9.0 起推荐 stdin）：
//   node write-active-session.js --stdin        # payload 从 stdin 读
//   node write-active-session.js '<json>'       # 兼容旧用法
//
// 为什么改成 stdin：payload 里有 refresh_token（有效期约 1 年），
// 走 argv 会出现在 `ps` 里，同机任意进程都能看到。stdin 不落进程列表。

const fs = require('fs');
const { encryptSessionPayload } = require('./extract-active-session.js');

let inputJson = process.argv[2];
if (inputJson === '--stdin') {
  inputJson = fs.readFileSync(0, 'utf8');
}
if (!inputJson) {
  console.log(JSON.stringify({ success: false, error: '未提供 session payload（argv 或 stdin）' }));
  process.exit(1);
}

try {
  console.log(JSON.stringify(encryptSessionPayload(inputJson)));
} catch (err) {
  console.log(JSON.stringify({ success: false, error: err.message }));
  process.exit(1);
}
