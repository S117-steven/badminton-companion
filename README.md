# 羽毛球运动分析

这是一个以 Apple Watch 为核心运动传感设备、以 iPhone 为长期数据管理终端的羽毛球个人表现分析项目。

阶段 0 工程基线与阶段 1 的 Simulator 采集闭环已经建立：双端工程、共享数据定义、测试者资料、采集会话、增量落盘、异常恢复、双文件入站校验和手机采集列表均可运行。下一步进入阶段 2，接入真实 Apple Watch 的 Core Motion 数据并完成真机数据质量验证。

## 当前工程

- `BadmintonMotion.xcodeproj`：iPhone 与 Apple Watch 内部研发版工程。
- `Apps/iOS`：iPhone 研发工具入口。
- `Apps/watchOS`：Apple Watch 研发采集入口。
- `Packages/BadmintonCore`：双端共享的研发数据模型、文件存储与核心测试。
- `羽毛球运动分析产品文档`：产品规范、研发门禁和技术基线。

Simulator 会生成确定性的流程测试数据，但每条采集都强制标记为 `simulator_synthetic`，不具备真机研究资格。当前代码不会生成自动击球分类或杀球速度；人工标签与原始数据保持独立，任何正式算法都必须等待真实数据和真机实验结论。

## 本地验证

```sh
./Scripts/verify.sh
```

部署到真实设备前，需要在 Xcode 中替换临时 Bundle Identifier、配置开发团队，并完成文档规定的真机验收。
