// Typeless Switchboard —— 把一份 userData JSON 写回 Typeless 本地会话缓存（静默换号用）
//
// 真正的加解密实现在 `extract-active-session.js`，这里只是薄包装。
// 以前这个文件的加解密逻辑是单独抄的一份，和读取端各改各的；
// 现在两边共用同一套派生逻辑，改一处即可。
//
// 用法：node write-active-session.js '<userData JSON 字符串>'

const { encryptSessionPayload } = require('./extract-active-session.js');

const inputJson = process.argv[2];
if (!inputJson) {
  console.log(JSON.stringify({ success: false, error: '未提供 session payload 参数' }));
  process.exit(1);
}

try {
  console.log(JSON.stringify(encryptSessionPayload(inputJson)));
} catch (err) {
  console.log(JSON.stringify({ success: false, error: err.message }));
  process.exit(1);
}
