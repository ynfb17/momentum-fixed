[EN README](./README_EN.md)

# Momentum - 心理学驱动的专注力应用

> **来源与修改 / Origin and modifications**
>
> 本仓库是 [KenXiao1/momentum](https://github.com/KenXiao1/momentum) 的修改副本。
> 初始代码取自 `new-feature-branch` 的 commit
> [`fa8aa97`](https://github.com/KenXiao1/momentum/commit/fa8aa9703d4c51c7ccce49a62f33ad345fec674c)
> （2026-11-25），原项目采用 **GPL-3.0**。
> 修改部分由 **Han Bao（@ynfb17）** 于 2026-11-26 完成，详见
> [ATTRIBUTION.md](ATTRIBUTION.md)。本修改版同样按 GPL-3.0 分发。
>
> This is a modified copy of [KenXiao1/momentum](https://github.com/KenXiao1/momentum),
> originally GPL-3.0. Modifications by Han Bao (@ynfb17), 2026-11-26; see
> [ATTRIBUTION.md](ATTRIBUTION.md).
>
> 本修改版在线示例（个人部署）：<https://momentum-fix-20261126.surge.sh>

开发与验证流程见 [CONTRIBUTING.md](CONTRIBUTING.md)，架构和领域说明见 [文档索引](docs/README.md)。

基于链式时延协议（CTDP）理论的自控力训练工具，通过"神圣座位原理"、"下必为例原理"和"线性时延原理"帮助用户建立强大的习惯链条。支持 Web（PWA）和 Tauri v2 桌面端（Windows/macOS/Linux）；移动端（iOS/Android）适配进行中。

详情请见：https://www.zhihu.com/question/19888447/answer/1930799480401293785

<img width="3000" height="1130" alt="image" src="https://github.com/user-attachments/assets/8765b5c0-4f7a-4d69-a826-d7a6bcef853f" />

你也可以在知乎上阅读此README：https://zhuanlan.zhihu.com/p/1932530006774505748

## ✨ 功能亮点

| 功能             | 描述                                   |
| ---------------- | -------------------------------------- |
| 🔗 链式任务管理  | 基于CTDP理论的习惯链条系统             |
| 📦 任务组/嵌套链 | 支持将多个任务组合成任务组，循环执行   |
| 🏛️ RSIP 国策系统 | 递归稳态迭代协议，建立个人生活规则体系 |
| 🐾 虚拟宠物系统  | 完成任务获得奖励，培养专属宠物         |
| 🎰 押注模式      | 可选的激励机制，为任务增加额外动力     |
| ⏱️ 正向计时器    | 支持无时长限制的任务                   |
| 🗑️ 回收站        | 软删除机制，可恢复误删的链条           |
| 📤 导入/导出     | 完整的数据备份与迁移支持               |
| ☁️ 云同步        | 支持 Supabase 多设备同步               |
| 🎨 玻璃拟态UI    | 现代化的毛玻璃界面设计                 |

## 🔀 Tauri 存储模式（v0.3.2）

- `tauri-desktop` / `tauri-mobile` 首次启动默认进入 **本地模式**。
- 当检测到 Supabase 配置时，会出现一次非阻塞提示卡，可选“继续本地模式”或“连接云端同步”。
- 设置页可随时在 **本地模式** 和 **云端模式** 间切换。
- 切换仅更换数据源，不做自动导入、导出或合并。
- 云端模式下宠物数值通过 `pet_state` 跨设备同步；位置、最小化和可见性仍按设备本地保存。本地模式全部保存在本机。

## 🎯 核心理念

Momentum基于Edmond在知乎上提出的链式时延协议（Chained Time-Delay Protocol, CTDP）理论，通过数学模型解决自制力问题：

$$I = \int_{0}^{\infty} V(\tau) \cdot W(\tau) d\tau$$

其中：

- `V(τ)` 是未来价值函数
- `W(τ)` 是权重贴现函数

<img width="931" height="676" alt="image" src="https://github.com/user-attachments/assets/138e50b6-4421-40bb-a214-017c588d832e" />

## 🔬 三大核心原理

### 1. 神圣座位原理

通过指定特定的触发动作（如"戴上降噪耳机"、"坐到书房书桌前"），创建一个"神圣座位"。一旦触发这个动作，就必须以最好的状态完成专注任务。每次成功完成任务，链条记录增长（#1 → #2 → #3...），形成强大的心理约束力。
<img width="1232" height="568" alt="image" src="https://github.com/user-attachments/assets/78cb2b9b-1eb1-4c0a-80d1-6a9500a3f4ab" />
<img width="1442" height="1652" alt="image" src="https://github.com/user-attachments/assets/4c68a170-31c8-4404-a3ea-a670a7090f2e" />
<img width="1178" height="1627" alt="image" src="https://github.com/user-attachments/assets/7b4593db-1c3e-414d-b0ea-24f55755cb56" />

### 2. 下必为例原理

当面临疑似违规行为时，只能选择：

- **判定失败**：链条清零，从#1重新开始
- **判定允许**：该行为永久加入例外规则，未来必须一律允许

这种"判例法"机制防止破窗效应，让规则边界收敛到最理性的状态。
<img width="2880" height="1370" alt="image" src="https://github.com/user-attachments/assets/f360fc69-0f33-4aab-bb1a-d5092d3f6133" />
<img width="1971" height="1551" alt="image" src="https://github.com/user-attachments/assets/692dda50-8265-4f56-97bd-11de5818ddcb" />

### 3. 线性时延原理

通过"预约链"解决启动困难：

- 设定预约信号（如"打响指"）
- 预约后必须在指定时间内开始主任务
- 利用时间延迟降低启动阻力<img width="911" height="890" alt="image" src="https://github.com/user-attachments/assets/247aec14-ec69-4fc7-aa14-112632814ca8" />
