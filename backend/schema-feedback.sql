-- SQLink 意见反馈表
-- 在 sqlink 库执行：mysql -h127.0.0.1 -P13306 -usqlink -p'<你的密码>' sqlink < schema-feedback.sql
CREATE TABLE IF NOT EXISTS feedback (
  id         INT          AUTO_INCREMENT PRIMARY KEY,
  email      VARCHAR(255) NOT NULL                       COMMENT '登录账号（邮箱）',
  content    TEXT         NOT NULL                       COMMENT '反馈内容',
  contact    VARCHAR(100) DEFAULT ''                    COMMENT '联系方式（邮箱/微信，选填）',
  ip         VARCHAR(64)  DEFAULT ''                    COMMENT '提交时客户端 IP',
  created_at DATETIME     DEFAULT CURRENT_TIMESTAMP     COMMENT '提交时间',
  status     TINYINT      DEFAULT 0                     COMMENT '0 未处理 1 已处理',
  INDEX idx_email   (email),
  INDEX idx_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户意见反馈';
