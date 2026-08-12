# 羽毛球运动分析

这是一个以 Apple Watch 为核心运动传感设备、以 iPhone 为长期数据管理终端的羽毛球个人表现分析项目。

当前处于阶段 0 向阶段 1 过渡期：先建立双端工程、共享数据定义、可靠的研发数据本地存储和内部采集入口，再通过真机数据验证逐步研究真实击球检测、杀球二分类和有真实测速基准的杀球速度估算。

## 当前工程

- `BadmintonMotion.xcodeproj`：iPhone 与 Apple Watch 内部研发版工程。
- `Apps/iOS`：iPhone 研发工具入口。
- `Apps/watchOS`：Apple Watch 研发采集入口。
- `Packages/BadmintonCore`：双端共享的研发数据模型、文件存储与核心测试。
- `羽毛球运动分析产品文档`：产品规范、研发门禁和技术基线。

当前代码不会生成自动击球分类或杀球速度。人工标签与原始数据保持独立，任何正式算法都必须等待真实数据和真机实验结论。

## 本地验证

```sh
swift test --package-path Packages/BadmintonCore
xcodebuild -project BadmintonMotion.xcodeproj -scheme BadmintonResearchiOS -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project BadmintonMotion.xcodeproj -scheme BadmintonResearchWatch -sdk watchsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

部署到真实设备前，需要在 Xcode 中替换临时 Bundle Identifier、配置开发团队，并完成文档规定的真机验收。
