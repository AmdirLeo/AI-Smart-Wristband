# AI Smart Wristband · 颐安·云护

AI 智能照护手环课程项目总仓库。手环采集运动数据，由 App 转发，服务端随机森林完成跌倒分类。当前已实现公开数据回放与推理服务，App 和手环连接由后续协作补充。

## 目录与分工

| 目录 | 内容 | 协作约定 |
|---|---|---|
| [`model_service/`](model_service/) | 训练代码、已训练模型、FastAPI 接口、浏览器演示及测试 | 模型与服务端开发 |
| [`app/`](app/) | App 代码预留位置，目前只有接入说明 | App 同事将完整工程提交到此目录，技术栈不限 |
| [`docs/API.md`](docs/API.md) | App 与模型服务的请求、响应、事件状态及联调方式 | 双方修改接口时同步更新 |

`model_service/app.py` 是 Python 服务入口；根目录 `app/` 是手机 App 工程位置。App 可在该目录内自行组织 Android、iOS 或跨平台项目，不需要移动模型代码。

## 启动模型服务

建议 Python 3.13。克隆本仓库后，在仓库根目录执行：

```bash
python -m pip install -r model_service/requirements-web.txt
python -B -m uvicorn app:app --app-dir model_service --host 127.0.0.1 --port 8000 --workers 1 --limit-concurrency 32
```

打开 http://127.0.0.1:8000 查看演示。模型和四条公开样例已包含在仓库中，无需重新训练、购买服务器或自行采集数据即可开始联调。

手机连接电脑、Web 跨域和访问口令配置见 [API 文档](docs/API.md)。云端与 Docker 操作见 [部署说明](model_service/DEPLOY.md)；Docker 镜像尚未实际构建验证。

## App 联调入口

1. `GET /health` 检查连接，`GET /api/info` 获取采样字段和确认时限。
2. `GET /api/samples/fall` 获取公开跌倒样例，只取其 `samples` 字段。
3. `POST /api/predict` 上传 `{"samples": [...]}`，展示返回的 `label` 和 `score`。
4. 若返回 `event`，轮询事件状态，并通过确认接口提交“安全”或“求助”。

当前接口接收完整 **10–20 秒**记录，尚不支持连续流、逐点推理或即时跌倒检测。通知为模拟流程，不会联系家属。详见 [接口约定](docs/API.md)。

## 模型与验证

当前上传的是原版 **45 特征随机森林**，使用 UMAFall 手腕六轴数据。737 条可用记录、19 名参与者的五折按人划分验证中，跌倒召回率为 93.03%，非跌倒记录误报率为 6.72%。这些是交叉验证汇总，不是线上真实用户效果；仓库模型为其中第 0 折模型。

```bash
python -B -m pytest -q -p no:cacheprovider model_service/test_pipeline.py model_service/test_app.py
```

训练、单位和数据限制见 [模型说明](model_service/README.md)。修改模型后须同步重建样例包，否则服务会因版本不一致拒绝启动。

## 协作方式与数据来源

同事先拉取本仓库，在 `app/` 内加入工程；建议通过功能分支和 Pull Request 合并。将服务地址设为 App 配置项，接口字段或单位变更先更新 `docs/API.md` 并协调两端修改。当前 API 无版本前缀，破坏性变更需共同确认。

公开数据：Eduardo Casilari、Jose A. Santoyo-Ramón，UMAFall v8，CC BY 4.0，[DOI](https://doi.org/10.6084/m9.figshare.4214283.v8)。仓库四条样例已做手腕通道筛选、对齐和重采样；复用或展示请保留署名。上述许可描述数据来源，不代表给整个仓库代码指定了许可证。
