# WiFi Handler (HarmonyOS + Flutter)



这是一个基于 Flutter 的 Wi-Fi 分析工具，专门设计用于在鸿蒙 (HarmonyOS) 平台上运行。它利用 `@ohos/flutter_ohos` 桥接技术，在鸿蒙原生 ArkTS 环境中托管 Flutter 应用，并实现了原生 API（如 Wi-Fi 扫描和文件操作）的调用。



## 核心功能



- **Wi-Fi 扫描与概览**：扫描并列出周围的 Wi-Fi 接入点 (AP)，显示它们的 SSID、BSSID、信号强度 (RSSI)、信道、频段和 Wi-Fi 标准（如 802.11ax）。
- **信道图表**：在“概览”页中，将 2.4G 和 5G/6G 的 AP 绘制在信道图上，直观展示信道占用情况。
- **实时信号分析**：在“分析”页，用户可以选择一个或多个 AP，应用将以平滑曲线图表的形式实时绘制它们的信号强度 (RSSI) 变化。
- **历史记录与导出**：允许用户将当前的扫描快照（可附带备注）保存为一条 JSONL 记录到设备上的文件中。
- **从历史载入分析**：在“分析”页，用户可以从导出的历史文件 (`.jsonl`) 中选择一条记录，应用会解析该记录中的 AP，并将其作为初始数据点绘制在图表上。
- **AI 网络建议**：在“从历史载入”后，应用会自动将该历史快照发送到用户配置的 OpenAI 兼容 API，获取针对当前 Wi-Fi 环境的详细优化建议。
- **个性化设置**：
  - **主题**：支持浅色、深色和跟随系统三种主题模式。
  - **AI 配置**：允许用户自定义 AI 基础域名（自动补全）、API Key 和模型名称。
- **调试与关于**：包含一个用于显示内部日志的“调试”页面和一个“关于”页面。



## 快速上手 (Getting Started)



本项目是一个标准的鸿蒙（ArkTS）项目，它在内部托管了一个 Flutter 模块。



### 先决条件



1. **Flutter SDK**：确保已安装 Flutter。
2. **DevEco Studio**：鸿蒙应用的主要 IDE。
3. **HarmonyOS SDK**：通过 DevEco Studio 安装。
4. **`@ohos/flutter_ohos` 依赖**：确保已按照 Flutter on HarmonyOS 的官方指引在鸿蒙项目中配置了此依赖。



### 项目结构（关键文件）



```
.
├── entry/                                # 鸿蒙原生模块
│   └── src/main/ets/entryability/
│       └── EntryAbility.ets              # 鸿蒙原生入口 & MethodChannel 处理器
├── lib/
│   ├── main.dart                         # Flutter 应用主入口、UI 和状态管理
│   ├── models/
│   │   └── history_record.dart           # HistoryRecord 数据模型
│   └── platform/
│       └── history_api.dart              # Flutter 端的 MethodChannel 封装 (file_ops)
├── assets/
│   └── oui_vendor.json                   # (需自行转换) OUI 厂商数据库
├── module.json5                          # 鸿蒙模块配置与权限声明
└── pubspec.yaml                          # Flutter 依赖 (http)
```



### 运行项目



1. **鸿蒙侧**：在 `entry` 目录中，确保 `oh-package.json5` 文件包含了 `@ohos/flutter_ohos` 依赖。
2. **Flutter 侧**：在项目根目录（或 Flutter 模块目录）运行 `flutter pub get` 来安装 `http` 等依赖库。
3. **构建与运行**：使用 DevEco Studio 打开项目根目录。DevEco Studio 会识别这是一个鸿蒙项目。
4. 选择一个已连接的鸿蒙设备或模拟器，点击“Run”按钮。DevEco Studio 将自动编译 ArkTS 和 Flutter 代码，并将应用安装到设备上。



## 技术架构



本项目是一个典型的 Flutter on HarmonyOS 混合应用。

1. **UI 与逻辑层 (Flutter - Dart)**：
   - `lib/main.dart`：包含几乎所有的 UI 界面（概览、分析、设置、调试、关于）、状态管理（使用 `ChangeNotifier` 和 `StatefulWidget`）和业务逻辑。
   - `SettingsService`：一个纯 Dart 的、仅在内存中的服务，用于管理主题和 AI 配置。**（注意：应用重启后设置会丢失）**。
   - `AiAnalyzerService`：使用纯 Dart 的 `http` 库，负责构建 Prompt 并向用户指定的 API 终结点发送请求。
   - `VendorDb`：在应用启动时从 `assets/oui_vendor.json` 加载数据，用于根据 BSSID (MAC) 查询设备厂商。
2. **原生桥接层 (ArkTS - HarmonyOS)**：
   - `entry/src/main/ets/entryability/EntryAbility.ets`：鸿蒙应用的**原生入口**。它负责初始化 `FlutterEngine` 并托管 Flutter UI。
   - `MethodChannel`：Dart 和 ArkTS 之间通过方法通道进行通信。`EntryAbility.ets` 作为所有原生调用的处理器。
3. **自定义方法通道 (MethodChannels)**：
   - `wifi_std`：用于 Wi-Fi 相关的原生调用。
     - `scanAndGet` (已修改)：在 ArkTS 端调用 `wifiManager.getScanInfoList()` 来**被动获取**系统缓存的扫描结果。
   - `file_ops`：用于文件系统相关的原生调用。
     - `chooseSaveUri` / `chooseOpenUri`：调用 `ohos.file.picker` 让用户选择文件。
     - `appendStart` / `appendChunk` / `appendFinish`：使用 `ohos.file.fs` API 向用户选择的文件 URI 中追加（写入）数据。
     - `history.listFromUri` / `history.deleteFromUri`：实现对 JSONL 历史文件的读取和删除。



## 关键功能详解





### 1. Wi-Fi 信号分析 (阶梯状曲线)



“分析”页的图表通过一个 `Timer` (每 2 秒) 定期调用 `wifi_std` 通道的 `scanAndGet` 方法。

**重要限制**：由于鸿蒙（及现代安卓）平台的权限限制，第三方应用**无法主动触发**高频 Wi-Fi 扫描。`EntryAbility.ets` 中调用的 `wifiManager.getScanInfoList()` 只是**被动地读取**系统上一次的扫描缓存。

- **表现**：因此，图表上的曲线在大多数时间内是**水平的**（因为 App 连续多次获取到的是同一份旧数据），直到鸿蒙系统在后台自行刷新了 Wi-Fi 列表，曲线才会**跳变**到新的 RSSI 值。这是一个“阶梯状”的曲线，是当前平台限制下的预期行为。



### 2. AI 分析流程



1. **触发**：用户在“分析”页点击“从历史载入”，并选择一条记录。
2. **加载**：`_loadFromHistory` 方法被调用。它解析 `HistoryRecord`，提取所有 AP 数据，并将其作为第一个数据点（t=0）填充到图表状态 `_history` 中。
3. **调用**：`_runAiAnalysis` 方法被触发。
4. **配置**：从 `SettingsService` 获取 API Key、模型和格式化后的 API 终结点（例如 `https://api.openai.com/v1/chat/completions`）。
5. **构建 Prompt**：应用将历史记录的 JSON 字符串和一个指导性 Prompt（要求分析信道重叠、信号强度等）结合。
6. **请求**：使用 `http` 库将请求发送到指定终结点。
7. **显示**：AI 返回的分析建议（已本地化）被显示在图表下方的“AI 网络分析”卡片中。



### 3. 设置的实现



为了避免编写鸿蒙原生的 `dataStorage` 插件代码，`SettingsService` 被实现为一个纯 Dart 的、仅在内存中的 `ChangeNotifier`。

- **优点**：100% 跨平台，无需原生桥接。
- **缺点**：当应用被系统彻底关闭后，所有设置（包括 API Key 和主题模式）都会丢失，下次启动需要重新配置。



## 如何配置和使用

### 1. 概览与保存历史



1. 打开 App，默认进入“概览”页。
2. 点击右上角的“设定导出文件”图标，选择一个位置（例如“下载”）并创建一个文件（如 `wifi_history.jsonl`）。
3. 点击“扫描”按钮 获取当前 Wi-Fi 列表。
4. （可选）在顶部的“备注”框中输入备注。
5. 点击“保存当前”图标，当前扫描结果和备注将被追加到您设定的文件中。



### 2. AI 分析



1. 导航到“设置”页面。
2. **配置 AI**：
   - **API 基础域名**：填入您的 API 服务域名（如 `api.openai.com` 或 `my.proxy.com`）。应用会自动为您补全 `https://` 和 `/v1/chat/completions`。
   - **模型名称**：填入您要使用的模型（如 `gpt-4o-mini`）。
   - **API Key**：填入您的 `sk-` 密钥。
   - 点击“保存 AI 设置”。
3. 导航到“分析”页面。
4. 点击“从历史载入”按钮。
5. 从弹出的“历史记录”页中选择一条您之前保存的记录。
6. 应用将自动加载数据、绘制图表，并触发 AI 分析。分析结果（可能需要几秒钟）将显示在图例下方的卡片中。

