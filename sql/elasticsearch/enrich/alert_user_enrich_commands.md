# Alert User Enrich Policy - 告警用户检测策略

## 功能说明

检测发件人邮箱是否为告警用户

**逻辑：**
- 如果 `sender_address` 在 `.mail-alert-user` 索引中存在 → `alertuser = true`
- 如果 `sender_address` 不在 `.mail-alert-user` 索引中 → `alertuser = false`

## 配置步骤

### 步骤 1: 创建 Enrich Policy

```json
PUT /_enrich/policy/alert_user_enrich_policy
{
  "match": {
    "indices": ".mail-alert-user",
    "match_field": "mail",
    "enrich_fields": ["username"]
  }
}
```

### 步骤 2: 执行 Enrich Policy（生成 Enrich 索引）

```json
PUT /_enrich/policy/alert_user_enrich_policy/_execute
```

### 步骤 3: 创建 Ingest Pipeline

#### 方式 1: 字符串格式（推荐，便于聚合和筛选）

```json
PUT /_ingest/pipeline/alert_user_enrich_pipeline
{
  "processors": [
    {
      "enrich": {
        "policy_name": "alert_user_enrich_policy",
        "field": "sender_address",
        "target_field": "alert_enriched_data",
        "max_matches": "1",
        "ignore_missing": false
      }
    },
    {
      "script": {
        "if": "ctx.alert_enriched_data != null",
        "source": "ctx.alertuser = 'true'",
        "lang": "painless"
      }
    },
    {
      "script": {
        "if": "ctx.alert_enriched_data == null",
        "source": "ctx.alertuser = 'false'",
        "lang": "painless"
      }
    }
  ]
}
```

#### 方式 2: 布尔格式

```json
PUT /_ingest/pipeline/alert_user_enrich_pipeline
{
  "processors": [
    {
      "enrich": {
        "policy_name": "alert_user_enrich_policy",
        "field": "sender_address",
        "target_field": "alert_enriched_data",
        "max_matches": "1",
        "ignore_missing": false
      }
    },
    {
      "script": {
        "if": "ctx.alert_enriched_data != null",
        "source": "ctx.alertuser = true",
        "lang": "painless"
      }
    },
    {
      "script": {
        "if": "ctx.alert_enriched_data == null",
        "source": "ctx.alertuser = false",
        "lang": "painless"
      }
    }
  ]
}
```

## 测试与验证

### 模拟测试 Pipeline（推荐先测试）

```json
# 测试匹配成功的情况（邮箱在 .mail-alert-user 中存在）
POST /_ingest/pipeline/alert_user_enrich_pipeline/_simulate
{
  "docs": [
    {
      "_source": {
        "sender_address": "wh1.sev@chintglobal.com"
      }
    }
  ]
}

# 预期结果：alertuser = "true"（字符串格式）或 true（布尔格式），alert_enriched_data 有值

# 测试匹配失败的情况（邮箱不存在）
POST /_ingest/pipeline/alert_user_enrich_pipeline/_simulate
{
  "docs": [
    {
      "_source": {
        "sender_address": "unknown@example.com"
      }
    }
  ]
}

# 预期结果：alertuser = "false"（字符串格式）或 false（布尔格式），alert_enriched_data = null
```

### 测试主 Pipeline 链（如果嵌套在其他 pipeline 中）

```json
# 测试完整的 pipeline 链
POST /_ingest/pipeline/your_main_pipeline/_simulate
{
  "docs": [
    {
      "_source": {
        "sender_address": "wh1.sev@chintglobal.com",
        "message": "your log message"
      }
    }
  ]
}

# 检查返回结果中是否包含 alertuser 字段
```

## 使用示例

### 在索引数据时应用 pipeline

```json
PUT /your_index/_doc/1?pipeline=alert_user_enrich_pipeline
{
  "sender_address": "alert@example.com",
  "subject": "Alert notification"
}
```

### 批量更新现有数据

```json
POST /your_index/_update_by_query?pipeline=alert_user_enrich_pipeline
{
  "query": {
    "match_all": {}
  }
}
```

## 管理命令

### 查看 Enrich Policy

```json
GET /_enrich/policy/alert_user_enrich_policy
```

### 查看 Ingest Pipeline

```json
GET /_ingest/pipeline/alert_user_enrich_pipeline
```

### 删除 Enrich Policy

```json
DELETE /_enrich/policy/alert_user_enrich_policy
```

### 删除 Ingest Pipeline

```json
DELETE /_ingest/pipeline/alert_user_enrich_pipeline
```

### 更新 alertuser 索引后，重新执行 policy

```json
PUT /_enrich/policy/alert_user_enrich_policy/_execute
```

## 聚合查询示例

### 字符串格式聚合（推荐）

```json
GET /your_index/_search
{
  "size": 0,
  "aggs": {
    "alertuser_stats": {
      "terms": {
        "field": "alertuser"
      }
    }
  }
}

# 筛选告警用户
GET /your_index/_search
{
  "query": {
    "term": {
      "alertuser": "true"
    }
  }
}
```

### 布尔格式聚合

```json
GET /your_index/_search
{
  "size": 0,
  "aggs": {
    "alertuser_stats": {
      "terms": {
        "field": "alertuser"
      }
    }
  }
}

# 筛选告警用户
GET /your_index/_search
{
  "query": {
    "term": {
      "alertuser": true
    }
  }
}
```

## 注意事项

- 需要先创建 `.mail-alert-user` 索引并包含 `mail` 字段
- 当 `.mail-alert-user` 索引更新后，需要重新执行 `_execute` 命令更新 enrich 索引
- `target_field` 使用 `alert_enriched_data` 避免与其他 enrich 策略冲突
- **如果嵌套在其他 pipeline 中，注意执行顺序**：确保 `sender_address` 字段在调用此 pipeline 前已存在
- 建议先使用 `_simulate` 测试 pipeline 是否正常工作，再应用到生产数据
- **字段格式选择**：
  - 字符串格式（`"true"`/`"false"`）：更适合聚合和可视化，Kibana 中显示更友好
  - 布尔格式（`true`/`false`）：占用空间更小，但在某些聚合场景下可能需要额外处理
