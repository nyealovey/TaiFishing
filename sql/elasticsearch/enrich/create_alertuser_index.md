# 创建 .mail-alert-user 索引

## 索引结构

包含两个字段：
- `mail`: 邮箱地址
- `username`: 用户名称

## 步骤 1: 创建索引 Mapping

```json
PUT /.mail-alert-user
{
  "mappings": {
    "properties": {
      "mail": {
        "type": "keyword"
      },
      "username": {
        "type": "keyword"
      }
    }
  }
}
```

## 步骤 2: 批量导入告警用户数据

```json
POST /.mail-alert-user/_bulk
{"index":{"_id":"1"}}
{"mail":"wh1.sev@chintglobal.com","username":"wh1.sev"}
{"index":{"_id":"2"}}
{"mail":"wh2.sev@chintglobal.com","username":"wh2.sev"}
{"index":{"_id":"3"}}
{"mail":"tender1.sev@chintglobal.com","username":"tender1.sev"}
{"index":{"_id":"4"}}
{"mail":"tender2.sev@chintglobal.com","username":"tender2.sev"}
{"index":{"_id":"5"}}
{"mail":"tender3.sev@chintglobal.com","username":"tender3.sev"}
{"index":{"_id":"6"}}
{"mail":"tender4.sev@chintglobal.com","username":"tender4.sev"}
{"index":{"_id":"7"}}
{"mail":"tender5.sev@chintglobal.com","username":"tender5.sev"}
{"index":{"_id":"8"}}
{"mail":"sales1.sev@chintglobal.com","username":"sales1.sev"}
{"index":{"_id":"9"}}
{"mail":"sales2.sev@chintglobal.com","username":"sales2.sev"}
{"index":{"_id":"10"}}
{"mail":"project1.sev@chintglobal.com","username":"project1.sev"}
{"index":{"_id":"11"}}
{"mail":"project2.sev@chintglobal.com","username":"project2.sev"}
{"index":{"_id":"12"}}
{"mail":"project3.sev@chintglobal.com","username":"project3.sev"}
{"index":{"_id":"13"}}
{"mail":"project4.sev@chintglobal.com","username":"project4.sev"}
{"index":{"_id":"14"}}
{"mail":"project5.sev@chintglobal.com","username":"project5.sev"}
{"index":{"_id":"15"}}
{"mail":"project6.sev@chintglobal.com","username":"project6.sev"}
{"index":{"_id":"16"}}
{"mail":"project7.sev@chintglobal.com","username":"project7.sev"}
{"index":{"_id":"17"}}
{"mail":"project9.sev@chintglobal.com","username":"project9.sev"}
{"index":{"_id":"18"}}
{"mail":"project11.sev@chintglobal.com","username":"project11.sev"}
{"index":{"_id":"19"}}
{"mail":"project13.sev@chintglobal.com","username":"project13.sev"}
{"index":{"_id":"20"}}
{"mail":"plan.sev@chintglobal.com","username":"plan.sev"}
{"index":{"_id":"21"}}
{"mail":"cnc1.sev@chintglobal.com","username":"cnc1.sev"}
{"index":{"_id":"22"}}
{"mail":"log.sev@chintglobal.com","username":"log.sev"}
{"index":{"_id":"23"}}
{"mail":"adm1.sev@chintglobal.com","username":"adm1.sev"}
{"index":{"_id":"24"}}
{"mail":"adm2.sev@chintglobal.com","username":"adm2.sev"}
{"index":{"_id":"25"}}
{"mail":"acc1.sev@chintglobal.com","username":"acc1.sev"}
{"index":{"_id":"26"}}
{"mail":"Alaeddine@chintglobal.com","username":"Alaeddine"}
{"index":{"_id":"27"}}
{"mail":"saleswest.kz01@chintglobal.com","username":"saleswest.kz01"}
{"index":{"_id":"28"}}
{"mail":"Beksultan.O@chintglobal.com","username":"Beksultan.O"}
{"index":{"_id":"29"}}
{"mail":"KakimzhanovaN@chintglobal.com","username":"KakimzhanovaN"}
{"index":{"_id":"30"}}
{"mail":"yelubayevam@chintglobal.com","username":"yelubayevam"}
```

## 验证数据

### 查看索引文档数量

```json
GET /.mail-alert-user/_count
```

### 查看所有数据

```json
GET /.mail-alert-user/_search
{
  "query": {
    "match_all": {}
  }
}
```

### 查询特定邮箱

```json
GET /.mail-alert-user/_search
{
  "query": {
    "term": {
      "mail": "wh1.sev@chintglobal.com"
    }
  }
}
```

## 管理操作

### 添加新用户

```json
POST /.mail-alert-user/_doc
{
  "mail": "newuser@chintglobal.com",
  "username": "newuser"
}
```

### 更新用户

```json
POST /.mail-alert-user/_update/1
{
  "doc": {
    "username": "wh1_updated"
  }
}
```

### 删除用户

```json
DELETE /.mail-alert-user/_doc/1
```

### 删除整个索引

```json
DELETE /.mail-alert-user
```

## 注意事项

- 索引创建后，需要执行 `alert_user_enrich_commands.md` 中的命令创建 enrich policy
- 每次更新 `.mail-alert-user` 索引后，需要重新执行 `PUT /_enrich/policy/alert_user_enrich_policy/_execute`
- `mail` 字段使用 `keyword` 类型，支持精确匹配
