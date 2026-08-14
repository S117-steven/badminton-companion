# 羽毛球运动分析

这是一个以 Apple Watch 为核心运动传感设备、以 iPhone 为长期数据管理终端的羽毛球个人表现分析项目。

阶段 0 工程基线、阶段 1 Simulator 采集闭环和阶段 3 研发数据管理工具已经建立。阶段 2 已有 Core Motion 与可重试、幂等去重的 WatchConnectivity 代码基线。阶段 4 已建立独立正式版 targets、羽毛球运动状态机、增量检查点、HealthKit 适配器、崩溃后平台会话重绑定和 Simulator 交互基线。正式运动现已具备独立的后台同步协议、手机长期本地存储、首次使用、个人资料、历史列表、单场报告、个人纪录空状态、校准状态和设置页面。真机数据质量、后台通信和 HealthKit 仍未验证。

## 当前工程

- `BadmintonMotion.xcodeproj`：研发版和正式版共四个独立 targets。
- `Apps/iOS`：iPhone 研发工具入口。
- `Apps/watchOS`：Apple Watch 研发采集入口。
- `Apps/Product`：不编译研发入口的正式 iPhone/Watch 代码。
- `Packages/BadmintonCore`：双端共享的数据模型、文件存储、服务与核心测试。
- `Scripts/analyze_research_exports.py`：对手机导出执行流式完整性与时序摘要，不运行击球或测速算法。
- `羽毛球运动分析产品文档`：产品规范、研发门禁和技术基线。

正式基础运动的模块、状态、权限、恢复边界和真机验收清单见 `羽毛球运动分析产品文档/18_基础运动记录技术基线.md`。正式运动同步、手机长期历史和 Simulator 验收边界见 `羽毛球运动分析产品文档/19_正式运动同步与手机历史技术基线.md`。

Simulator 采集和运动数据都强制标记为 `simulator_synthetic`，不写入 Apple 健康，也不具备真机研究资格。当前代码不会生成击球识别、杀球分类或杀球速度。

## 本地验证

```sh
./Scripts/verify.sh
```

分析单个导出或整个批量目录：

```sh
python3 Scripts/analyze_research_exports.py path/to/export-or-directory
```

部署到真实设备前，需要在 Xcode 中替换临时 Bundle Identifier、配置开发团队，并完成文档规定的真机验收。
