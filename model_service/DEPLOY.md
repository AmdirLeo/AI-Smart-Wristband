# 颐安·云护：推理服务与演示页面

现在可以在本机运行完整演示，无需先购买服务器，也无需自行采集数据。只有需要别人从互联网访问时，才需要云服务器或支持 Docker 的应用托管平台。

## 本机启动

在项目根目录运行，适用于 Windows PowerShell 或 Linux 终端：

```bash
python -m pip install -r model_service/requirements-web.txt
python -B -m uvicorn app:app --app-dir model_service --host 127.0.0.1 --port 8000 --workers 1 --limit-concurrency 32
```

然后打开 **http://127.0.0.1:8000**。终端保持运行，按 Ctrl+C 停止服务。本机默认不用口令，直接选择示例。

页面提供以下操作：

1. 选择日常动作、模拟跌倒、误报或漏检案例。四条案例均来自当前模型训练时留出的参与者 18。
2. 点击“开始回放并识别”，支持暂停、继续及 4 倍速；完整记录回放结束后才向服务提交推理。也可点击“直接识别整段”。
3. 查看加速度曲线、模型分数、分类阈值以及与公开标签的对照。
4. 疑似跌倒时，选择“我没事”或“需要帮助”；20 秒未确认则显示模拟通知。不会发送真实短信或联系家属。
5. 可导入符合 [模型说明](README.md) 格式的 CSV。页面和接口均不保存上传文件。

演示页面只加载本项目资源，不依赖外部图表 CDN。示例数据已随程序提供，启动服务不会再下载 78 MB 的原始数据集。

## 服务器怎么选

单人或少量同学演示，可以先选国内云厂商的 **2 核 CPU、2 GB RAM 的 Linux 轻量应用服务器**，无需 GPU；磁盘预留约 10 GB 用于系统之外的镜像和更新。Ubuntu 24.04 LTS 等能运行 Docker 的系统即可。实际并发能力需以所选机器的测量为准。

云端运行的是 Python 模型服务，浏览器负责展示。以后接入手环时，可由手机或网关转发六轴数据，无需把模型放进手环固件。当前已经实现公开数据回放，尚未实现蓝牙连接和手机网关。

公网部署的前提是已有云主机或托管账号、访问方式及必要的域名配置；本次尚未购买服务器或发布公网地址。

## Docker 部署

本项目包含 Dockerfile 和构建白名单。先把整个 `model_service` 文件夹上传到服务器，在该文件夹内运行：

```bash
docker build -t yunhu-demo:1 .

# 在服务器终端输入自选的较长访问口令，不写入口令文件或命令历史
read -rsp '演示访问口令: ' DEMO_ACCESS_TOKEN
export DEMO_ACCESS_TOKEN
test -n "$DEMO_ACCESS_TOKEN"

docker run -d --name yunhu-demo --restart unless-stopped \
  -p 127.0.0.1:8000:8000 \
  -e DEMO_ACCESS_TOKEN \
  --memory=1500m --cpus=2 \
  yunhu-demo:1

unset DEMO_ACCESS_TOKEN
curl http://127.0.0.1:8000/health
```

`test` 返回非零时先重新设置口令再启动容器。容器采用非 root 用户、单进程服务及 32 个并发连接上限。默认将端口绑定到服务器本机，避免跳过 HTTPS 反向代理直接公开接口。

如果暂时没有域名，可在自己电脑上建立 SSH 隧道，演示时不必开放公网 8000 端口：

```bash
ssh -N -L 8000:127.0.0.1:8000 your-user@your-server-ip
```

随后在自己电脑打开 http://127.0.0.1:8000，输入刚设置的访问口令。这适合课堂投屏，但不是可分享给所有人的公开网址。

如果需要公开网址，可用服务器上的 Caddy 或 Nginx 提供 HTTPS，并反向代理到 `127.0.0.1:8000`。Caddy 的配置示例为：

```caddyfile
demo.your-domain.com {
    reverse_proxy 127.0.0.1:8000
}
```

将域名解析到服务器，并按云厂商要求配置安全组和中国内地网站域名备案。公网演示时设置 `DEMO_ACCESS_TOKEN`，通过 HTTPS 输入及传输口令；所有 `/api/` 接口都验证该口令。页面本身和不含模型数据的 `/health` 健康检查公开可读。

当前执行环境没有 Docker，因此本次验证覆盖 Python 服务和浏览器操作，**未实际构建或运行容器镜像**。上线时需执行上述构建、健康检查及一条样例推理，才能确认目标机器部署成功。

## 接口约定

App 同事请以 [完整接口对接说明](../docs/API.md) 为入口，包含字段、错误码、网络配置和联调顺序。

设置访问口令后，以下 `/api/` 请求都需要 `Authorization: Bearer <口令>`。接口统一使用当前保存的模型及阈值，客户端不能指定任意模型文件。

| 方法及路径 | 功能 |
|---|---|
| `GET /health` | 服务健康状态 |
| `GET /api/info` | 数据格式、验证指标及确认时限 |
| `GET /api/samples` | 四条演示记录的元信息 |
| `GET /api/samples/{id}` | 某条记录及其六轴采样值 |
| `POST /api/predict` | 接收 JSON 六轴记录，输出模型结果 |
| `POST /api/predict-csv` | 接收原始 UTF-8 CSV 内容，输出模型结果 |
| `GET /api/events/{id}` | 查询模拟确认事件状态 |
| `POST /api/events/{id}/confirm` | 提交 `{"choice":"safe"}` 或 `{"choice":"help"}` |

`/api/predict` 输入：

```json
{"samples":[[0.00,0.01,0.02,1.00,0.2,0.1,0.3],[0.05,0.02,0.01,1.01,0.1,0.2,0.1]]}
```

上面只展示两行格式，不能直接用于推理；实际须提交 10–20 秒完整记录。每行顺序固定为 `timestamp_s, ax_g, ay_g, az_g, gx_dps, gy_dps, gz_dps`。时间单位秒、加速度单位 g（保留重力）、陀螺仪单位 °/s。

`/api/predict-csv` 的请求体是 CSV 原文，而非 multipart 文件表单，建议 `Content-Type: text/csv`。两个推理接口最多接收 2 MB、4000 行采样；非法值、缺失通道、超长间断及错误时长返回 422，超过大小限制返回 413。

输出包含 `label`、`score`、`threshold`、`mode` 和 `event`。`score` 是未经校准的分类分数。仅 `suspected_fall` 会创建演示事件；非跌倒的 `event` 为 `null`。

事件状态变化：

- `pending → safe`：用户确认安全。
- `pending → help_requested`：用户求助，页面显示模拟通知。
- `pending → simulated_notification`：超过服务器记录的 20 秒截止时间。

终态不能改写；重复提交同一确认返回已有结果。超时状态在后续读取或确认时根据服务器时间更新，页面每秒查询；没有后台通知任务。即使关闭页面，也不会真的通知任何人。

事件仅存于服务进程内存，最多 512 条，保留最多 1 小时，服务重启后清空。因此部署必须使用 **一个 worker、一个实例**，本版不支持多副本事件同步。原始上传信号不会存入事件或日志文件，也没有历史记录数据库。

## 数据和模型维护

`demo_samples.json` 是页面运行所需的最终样例资源，包含四条经过筛选、对齐和重采样的公开记录及出处，不是训练中间文件。这四条分别展示混淆矩阵中的四种结果，不能用它们计算总体准确率。

样例包记录了 `model.joblib` 的 SHA-256。更换或重新训练模型后，需要同步生成样例，否则服务会拒绝启动，避免页面标签与模型版本不一致：

```bash
python -B model_service/prepare_demo.py
```

该命令自动临时下载指定修正版 UMAFall 数据并在结束后清理，只保留最终样例 JSON；也可以用 `--data-zip` 指定已有 ZIP。它根据模型报告中的留出参与者，依文件名排序选择四类结果的首条可用记录。如果新模型的留出数据缺少某类结果，会明确报错，不会伪造案例。

数据来源：Eduardo Casilari、Jose A. Santoyo-Ramón，UMAFall v8，CC BY 4.0；[DOI](https://doi.org/10.6084/m9.figshare.4214283.v8)。发布演示时保留页面中的来源署名。

## 验证

```bash
python -B -m pytest -q -p no:cacheprovider model_service/test_pipeline.py model_service/test_app.py
```

测试覆盖真实模型的四类案例、参与者留出范围、CSV/JSON 一致性、认证、输入大小和数据质量、确认幂等、超时与过期事件、模型版本匹配。浏览器还应检查回放暂停/继续、CSV 导入、确认操作、20 秒超时及手机窄屏布局。

这套应用适合课程演示。它使用完整动作记录的事后分类，尚不是连续实时跌倒监测系统，公开数据验证结果也不能当成实际老人佩戴可靠性的证明。
