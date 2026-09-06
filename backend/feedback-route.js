// ============================================================
// SQLink 意见反馈接口  POST /api/feedback
// ------------------------------------------------------------
// 如何接入你的 app.js（假设与现有代码一致，按实际变量名微调）：
//   1) 确认你的鉴权中间件把登录邮箱挂到 req 上，例如：
//        app.use('/api/feedback', requireAuth)  // 或 inline
//      并约定 req.user.email（或 req.userEmail）为登录邮箱。
//   2) 确认已存在：express 实例 `app`、mysql2 连接池 `pool`、redis 客户端 `redisClient`。
//   3) 把下面这段粘进 app.js（或拆成 routes/feedback.js 后 require）。
//   4) 先跑 schema-feedback.sql 建表，再 `pm2 restart sqlink-api`。
// ============================================================

app.post('/api/feedback', authenticate, async (req, res) => {
  // ---------- 1. 取账号与 IP ----------
  const email = (req.user && req.user.email) || req.userEmail || '';
  if (!email) {
    return res.json({ code: 401, message: '未登录或登录已失效' });
  }
  // 取真实客户端 IP：你的 Node 在 Nginx 反代之后，需读 x-forwarded-for
  const xff = req.headers['x-forwarded-for'];
  const ip = (xff ? xff.split(',')[0].trim() : (req.socket.remoteAddress || 'unknown'));

  // ---------- 2. 输入校验（服务端兜底，前端也校验过） ----------
  const content = (req.body.content || '').toString().trim();
  const contact = (req.body.contact || '').toString().trim();
  if (!content) {
    return res.json({ code: 400, message: '反馈内容不能为空' });
  }
  if (content.length > 1000) {
    return res.json({ code: 400, message: '反馈内容过长（最多 1000 字）' });
  }
  if (contact.length > 100) {
    return res.json({ code: 400, message: '联系方式过长（最多 100 字）' });
  }

  // ---------- 3. 防爆破：每账号 + 每 IP 滑动窗口限流 ----------
  // 窗口 1 小时；账号上限 5 次、IP 上限 20 次。
  const WINDOW = 3600;
  const USER_LIMIT = 5;
  const IP_LIMIT = 20;
  const uKey = `fb:rl:u:${email}`;
  const iKey = `fb:rl:ip:${ip}`;
  try {
    const uc = await redisClient.incr(uKey);
    if (uc === 1) await redisClient.expire(uKey, WINDOW);   // 首次写入才设过期，避免每次重置窗口
    if (uc > USER_LIMIT) {
      return res.json({ code: 429, message: '提交过于频繁，请 1 小时后再试' });
    }
    const ic = await redisClient.incr(iKey);
    if (ic === 1) await redisClient.expire(iKey, WINDOW);
    if (ic > IP_LIMIT) {
      return res.json({ code: 429, message: '提交过于频繁，请稍后再试' });
    }
  } catch (e) {
    // redis 异常不阻断业务，仅记录（限流失效但功能可用，优于直接 500）
    console.error('[feedback] ratelimit error:', e);
  }

  // ---------- 4. 入库 ----------
  try {
    await pool.execute(
      'INSERT INTO feedback (email, content, contact, ip, created_at) VALUES (?, ?, ?, ?, NOW())',
      [email, content, contact, ip]
    );
    return res.json({ code: 200, message: '已收到你的反馈，感谢支持！' });
  } catch (e) {
    console.error('[feedback] insert error:', e);
    return res.json({ code: 500, message: '提交失败，请稍后重试' });
  }
});
