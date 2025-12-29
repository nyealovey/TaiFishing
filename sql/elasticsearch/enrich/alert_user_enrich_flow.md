# Alert User Enrich 流程图

## 整体架构流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          数据采集层 (Filebeat)                            │
│                                                                           │
│  Exchange 日志文件 → Filebeat 采集 → 发送到 Elasticsearch                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                    主 Ingest Pipeline 处理                                │
│              (filebeat-8.0.1-iis-access-pipeline-account)                │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 1. Grok 解析日志                                                  │   │
│  │    - 提取 sender_address, user.name 等字段                        │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    ↓                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 2. Date 处理                                                      │   │
│  │    - 转换时间格式为 @timestamp                                     │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    ↓                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 3. User Agent 解析                                                │   │
│  │    - 解析浏览器和操作系统信息                                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    ↓                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 4. GeoIP 处理                                                     │   │
│  │    - 添加地理位置信息                                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    ↓                                      │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 5. 嵌套 Pipeline 调用（按顺序执行）                                │   │
│  │                                                                   │   │
│  │    Pipeline 1: aduser_enrich_pipeline                            │   │
│  │    ├─ ignore_failure: true                                       │   │
│  │    └─ 功能：AD 用户信息补充                                        │   │
│  │                                                                   │   │
│  │    Pipeline 2: exchange_enrich_pipeline                          │   │
│  │    ├─ ignore_failure: true                                       │   │
│  │    └─ 功能：Exchange 相关信息补充                                  │   │
│  │                                                                   │   │
│  │    Pipeline 3: alert_user_enrich_pipeline  ← 本文档重点           │   │
│  │    ├─ ignore_failure: true                                       │   │
│  │    └─ 功能：告警用户标记                                           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│                        写入目标索引                                        │
│                  (filebeat-exchange-2025.12-000260)                      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Alert User Enrich Pipeline 详细流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   alert_user_enrich_pipeline 执行流程                     │
└─────────────────────────────────────────────────────────────────────────┘

输入文档示例：
{
  "sender_address": "wh1.sev@chintglobal.com",
  "subject": "Alert notification",
  ...其他字段
}

                                    ↓

┌─────────────────────────────────────────────────────────────────────────┐
│ Processor 1: Enrich Processor                                            │
│                                                                           │
│  配置：                                                                    │
│  - policy_name: alert_user_enrich_policy                                 │
│  - field: sender_address                                                 │
│  - target_field: alert_enriched_data                                     │
│  - max_matches: 1                                                        │
│                                                                           │
│  执行逻辑：                                                                │
│  1. 读取 sender_address 字段值                                            │
│  2. 在 Enrich 索引中查找匹配记录                                           │
│     (.enrich-alert_user_enrich_policy-*)                                 │
│  3. 如果找到匹配：                                                         │
│     └─ 将匹配的数据写入 alert_enriched_data 字段                          │
│  4. 如果未找到：                                                           │
│     └─ alert_enriched_data 保持为 null                                   │
└─────────────────────────────────────────────────────────────────────────┘

                    ↓ 匹配成功                    ↓ 匹配失败
                    
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│ 文档状态（匹配成功）               │    │ 文档状态（匹配失败）               │
│                                  │    │                                  │
│ {                                │    │ {                                │
│   "sender_address": "wh1.sev...",│    │   "sender_address": "unknown...",│
│   "alert_enriched_data": {       │    │   "alert_enriched_data": null    │
│     "mail": "wh1.sev@...",       │    │ }                                │
│     "username": "wh1.sev"        │    │                                  │
│   }                              │    │                                  │
│ }                                │    │                                  │
└──────────────────────────────────┘    └──────────────────────────────────┘
                    ↓                                    ↓

┌─────────────────────────────────────────────────────────────────────────┐
│ Processor 2: Script Processor (设置 alertuser = true)                    │
│                                                                           │
│  条件：if "ctx.alert_enriched_data != null"                              │
│  脚本：ctx.alertuser = 'true'  (字符串格式)                               │
│                                                                           │
│  执行：                                                                    │
│  - 检查 alert_enriched_data 是否存在                                      │
│  - 如果存在 → 设置 alertuser = 'true'                                     │
│  - 如果不存在 → 跳过此 processor                                          │
└─────────────────────────────────────────────────────────────────────────┘

                    ↓ 条件满足                    ↓ 条件不满足（跳过）

┌─────────────────────────────────────────────────────────────────────────┐
│ Processor 3: Script Processor (设置 alertuser = false)                   │
│                                                                           │
│  条件：if "ctx.alert_enriched_data == null"                              │
│  脚本：ctx.alertuser = 'false'  (字符串格式)                              │
│                                                                           │
│  执行：                                                                    │
│  - 检查 alert_enriched_data 是否为 null                                  │
│  - 如果为 null → 设置 alertuser = 'false'                                │
│  - 如果不为 null → 跳过此 processor                                       │
└─────────────────────────────────────────────────────────────────────────┘

                    ↓ 条件满足                    ↓ 条件不满足（跳过）

┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│ 最终输出（告警用户）               │    │ 最终输出（非告警用户）             │
│                                  │    │                                  │
│ {                                │    │ {                                │
│   "sender_address": "wh1.sev...",│    │   "sender_address": "unknown...",│
│   "alert_enriched_data": {       │    │   "alert_enriched_data": null,   │
│     "mail": "wh1.sev@...",       │    │   "alertuser": "false"           │
│     "username": "wh1.sev"        │    │ }                                │
│   },                             │    │                                  │
│   "alertuser": "true"            │    │                                  │
│ }                                │    │                                  │
└──────────────────────────────────┘    └──────────────────────────────────┘
```

## Enrich Policy 与索引关系

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Enrich Policy 生命周期                             │
└─────────────────────────────────────────────────────────────────────────┘

步骤 1: 创建源索引
┌──────────────────────────────────┐
│   .mail-alert-user 索引           │
│                                  │
│  文档 1:                          │
│  {                               │
│    "mail": "wh1.sev@...",        │
│    "username": "wh1.sev"         │
│  }                               │
│                                  │
│  文档 2:                          │
│  {                               │
│    "mail": "wh2.sev@...",        │
│    "username": "wh2.sev"         │
│  }                               │
│  ...                             │
└──────────────────────────────────┘
                ↓
步骤 2: 创建 Enrich Policy
┌──────────────────────────────────┐
│  alert_user_enrich_policy        │
│                                  │
│  - indices: .mail-alert-user     │
│  - match_field: mail             │
│  - enrich_fields: [username]     │
└──────────────────────────────────┘
                ↓
步骤 3: 执行 Policy (_execute)
┌──────────────────────────────────┐
│  生成 Enrich 索引                 │
│  .enrich-alert_user_enrich_      │
│  policy-<timestamp>              │
│                                  │
│  这是一个只读的优化索引，          │
│  专门用于快速匹配查询              │
└──────────────────────────────────┘
                ↓
步骤 4: Pipeline 使用 Enrich 索引
┌──────────────────────────────────┐
│  alert_user_enrich_pipeline      │
│  在处理文档时，从 Enrich 索引      │
│  中查找匹配数据                    │
└──────────────────────────────────┘

注意：
- 当 .mail-alert-user 索引更新后，需要重新执行 _execute
- Enrich 索引不会自动更新，必须手动触发
```

## 数据流向总览

```
┌─────────────┐
│ Exchange    │
│ 日志文件     │
└──────┬──────┘
       │
       ↓
┌─────────────┐
│  Filebeat   │
│  采集器      │
└──────┬──────┘
       │
       ↓
┌─────────────────────────────────────────────────────────┐
│           Elasticsearch Ingest Pipeline                 │
│                                                          │
│  ┌────────────────────────────────────────────────┐    │
│  │  主 Pipeline (IIS Access)                       │    │
│  │  ├─ Grok 解析                                   │    │
│  │  ├─ Date 转换                                   │    │
│  │  ├─ User Agent 解析                             │    │
│  │  ├─ GeoIP 处理                                  │    │
│  │  └─ 嵌套 Pipeline 调用                          │    │
│  │      ├─ aduser_enrich_pipeline                 │    │
│  │      ├─ exchange_enrich_pipeline               │    │
│  │      └─ alert_user_enrich_pipeline             │    │
│  └────────────────────────────────────────────────┘    │
│                          ↓                               │
│  ┌────────────────────────────────────────────────┐    │
│  │  alert_user_enrich_pipeline                    │    │
│  │  ├─ Enrich Processor                           │    │
│  │  │   └─ 查询 .enrich-alert_user_enrich_policy-*│    │
│  │  ├─ Script: set alertuser = 'true'             │    │
│  │  └─ Script: set alertuser = 'false'            │    │
│  └────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
       │
       ↓
┌─────────────────────────────────┐      ┌──────────────────────────┐
│  目标索引                         │      │  Enrich 源索引            │
│  filebeat-exchange-2025.12-*    │      │  .mail-alert-user        │
│                                 │      │  (告警用户列表)           │
│  包含 alertuser 字段             │      └──────────────────────────┘
└─────────────────────────────────┘                 ↓
       │                                   ┌──────────────────────────┐
       ↓                                   │  Enrich 索引              │
┌─────────────────────────────────┐      │  .enrich-alert_user_     │
│  Kibana 可视化                   │      │  enrich_policy-*         │
│  - 按 alertuser 聚合             │      │  (只读优化索引)           │
│  - 筛选告警用户邮件              │      └──────────────────────────┘
└─────────────────────────────────┘
```

## 关键配置点

### 1. 主 Pipeline 中的嵌套调用顺序

```json
{
  "processors": [
    // ... 前面的 processors ...
    
    // 顺序很重要！
    {"pipeline": {"name": "aduser_enrich_pipeline", "ignore_failure": true}},
    {"pipeline": {"name": "exchange_enrich_pipeline", "ignore_failure": true}},
    {"pipeline": {"name": "alert_user_enrich_pipeline", "ignore_failure": true}}
    
    // alert_user_enrich_pipeline 必须在 sender_address 字段存在后才能执行
  ]
}
```

### 2. Enrich Policy 配置

```json
{
  "match": {
    "indices": ".mail-alert-user",      // 源索引
    "match_field": "mail",              // 匹配字段（源索引中）
    "enrich_fields": ["username"]       // 要补充的字段
  }
}
```

### 3. Enrich Processor 配置

```json
{
  "enrich": {
    "policy_name": "alert_user_enrich_policy",  // 使用的 policy
    "field": "sender_address",                  // 文档中要匹配的字段
    "target_field": "alert_enriched_data",      // 结果存放位置
    "max_matches": "1"                          // 最多匹配数量
  }
}
```

## 故障排查流程

```
问题：alertuser 字段没有生成

    ↓
    
检查 1: 源索引是否存在？
GET /.mail-alert-user/_count
    ↓ 是
    
检查 2: Enrich Policy 是否创建？
GET /_enrich/policy/alert_user_enrich_policy
    ↓ 是
    
检查 3: Enrich 索引是否生成？
GET /_cat/indices/.enrich*?v
    ↓ 是
    
检查 4: Pipeline 是否正确配置？
GET /_ingest/pipeline/alert_user_enrich_pipeline
    ↓ 是
    
检查 5: 模拟测试是否通过？
POST /_ingest/pipeline/alert_user_enrich_pipeline/_simulate
    ↓ 是
    
检查 6: 主 Pipeline 中是否正确调用？
GET /_ingest/pipeline/filebeat-8.0.1-iis-access-pipeline-account
    ↓ 是
    
检查 7: 调用顺序是否正确？
确保 sender_address 字段在调用 alert_user_enrich_pipeline 前已存在
    ↓ 是
    
检查 8: ignore_failure 是否隐藏了错误？
将 ignore_failure 改为 false，查看实际错误信息
```
