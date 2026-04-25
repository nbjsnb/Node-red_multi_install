# Node-RED Multi Install

这个项目用于准备和安装多套 Node-RED 运行环境:

- 下载并保存离线安装包到 `pkg\`
- 离线安装 Node-RED 3.x 和 4.x
- 为每个端口生成独立的 `userDir`
- 统一使用 `start-nr.bat <version> <port>` 启动

各脚本分工如下:

- `01.download-nodejs.ps1` 下载 Node.js zip
- `02.download-node-red.ps1` 生成 Node-RED 离线 zip
- `03.install-offline.ps1` 执行离线安装并生成 `start-nr.bat`
- `start-nr.bat` 启动指定版本和端口的 Node-RED 实例

## 目录结构

项目目录:

```text
Node-red_multi_install/
├─ 01.download-nodejs.ps1
├─ 02.download-node-red.ps1
├─ 03.install-offline.ps1
├─ node-red-multi-install.ps1
├─ pkg/
└─ README.md
```

安装完成后，安装目录中会生成这些内容:

```text
<InstallRoot>/
├─ nodejs14 / nodejs16 / nodejs18 / nodejs20 / nodejs22
├─ node-red3.x
├─ node-red4.x
├─ prj/
├─ start-nr.bat
└─ node-red-multi-install-result.json
```

其中:

- `prj\` 保存各实例的 `userDir`
- 整个 `<InstallRoot>` 可以作为绿色版目录整体拷贝到其他位置运行

## 推荐流程

### 1. 下载 Node.js 离线包

```powershell
.\01.download-nodejs.ps1
```

常用参数:

- `-Force`
  重新下载已有 zip
- `-UseProxyEnv`
  使用当前代理环境变量
- `-MirrorProfile official`
- `-MirrorProfile taobao`
- `-NodeMirrorBase https://your-mirror.example.com/dist`

示例:

```powershell
.\01.download-nodejs.ps1 -MirrorProfile taobao
.\01.download-nodejs.ps1 -UseProxyEnv
.\01.download-nodejs.ps1 -MirrorProfile custom -NodeMirrorBase https://nodejs.org/dist
```

脚本会下载这些 Node.js Windows x64 zip:

- `node-v14.21.3-win-x64.zip`
- `node-v16.20.2-win-x64.zip`
- `node-v18.20.4-win-x64.zip`
- `node-v20.11.1-win-x64.zip`
- `node-v22.22.2-win-x64.zip`

### 2. 生成 Node-RED 离线包

```powershell
.\02.download-node-red.ps1
```

这个脚本会在临时目录里用对应的 Node.js toolchain 执行 `npm install`，最后把结果压成:

- `pkg\node-red-3.x.zip`
- `pkg\node-red-4.x.zip`

常用参数:

- `-Force`
  重新生成 zip
- `-NodeRed3Spec ^3`
- `-NodeRed4Spec ^4`
- `-UseProxyEnv`
  使用当前代理环境变量
- `-MirrorProfile official`
- `-MirrorProfile taobao`
- `-NpmRegistry https://registry.npmjs.org/`

示例:

```powershell
.\02.download-node-red.ps1 -MirrorProfile taobao
.\02.download-node-red.ps1 -NodeRed3Spec 3.1.15 -NodeRed4Spec 4.1.1
.\02.download-node-red.ps1 -UseProxyEnv
```

### 3. 离线安装并生成启动脚本

```powershell
.\03.install-offline.ps1 -Install
```

安装完成后，请通过 `start-nr.bat` 启动实例。

常用参数:

- `-InstallRoot D:\nr`
  指定安装目录
- `-Force`
  强制重装已有目录
- `-Nr3Version 16`
- `-Nr3Version node-v16.20.2-win-x64.zip`
- `-Nr4Version 22`
- `-Nr4Version node-v22.22.2-win-x64.zip`

示例:

```powershell
.\03.install-offline.ps1 -Install
.\03.install-offline.ps1 -Install -InstallRoot D:\nr
.\03.install-offline.ps1 -Install -Nr3Version 16 -Nr4Version 22
.\03.install-offline.ps1 -Install -Force
```

查看当前 `pkg\` 里有哪些包:

```powershell
.\03.install-offline.ps1 -ListPkg
```

## 启动方式

安装完成后，请进入安装目录，使用下面的格式启动:

```bat
start-nr.bat 3 1880
start-nr.bat 3 1881
start-nr.bat 4 1990
start-nr.bat 4 1991
```

批量开多个实例:

```bat
start "" .\start-nr.bat 3 1880
start "" .\start-nr.bat 3 1881
start "" .\start-nr.bat 4 1990
start "" .\start-nr.bat 4 1991
```

每个实例的 `userDir` 位于 `prj\` 下，并按版本和端口分开:

- `prj\nr3-1880`
- `prj\nr3-1881`
- `prj\nr4-1990`
- `prj\nr4-1991`

## 版本兼容关系

- Node-RED 3.x -> Node.js 14 或 16
- Node-RED 4.x -> Node.js 18、20 或 22

如果 `03.install-offline.ps1` 不指定版本，它会优先选择:

- NR3 优先 `16`，其次 `14`
- NR4 优先 `22`，其次 `20`，最后 `18`

## 交互模式

直接双击或无参数运行 `03.install-offline.ps1` 时，会进入一个简单菜单:

- `1` 查看 `pkg` 包列表
- `2` 执行离线安装
- `3` 退出

这个菜单提供安装相关操作，启动入口仍然是 `start-nr.bat`。

## 常见用法

### 一台联网机器准备离线包

```powershell
.\01.download-nodejs.ps1 -MirrorProfile taobao
.\02.download-node-red.ps1 -MirrorProfile taobao
```

然后把整个项目目录，或者至少把 `pkg\` 拷到目标机器。

### 在目标机器离线安装

```powershell
.\03.install-offline.ps1 -Install -InstallRoot D:\nr
cd D:\nr
.\start-nr.bat 3 1880
```

### 绿色版迁移

安装完成后，可以把整个安装目录直接复制到任意位置使用，例如:

```text
D:\nr  ->  E:\tools\node-red-portable
```

复制后进入新目录，仍然按同样方式启动:

```powershell
cd E:\tools\node-red-portable
.\start-nr.bat 3 1880
```

### 固定 Node.js 大版本

```powershell
.\03.install-offline.ps1 -Install -Nr3Version 14 -Nr4Version 20
```

## 生成结果

安装完成后会生成一个结果文件:

```text
node-red-multi-install-result.json
```

里面会记录:

- 安装根目录
- 已安装的 Node-RED 版本
- 推荐启动命令

## 注意事项

- 请先执行 `01`，再执行 `02`，最后执行 `03`
- `02.download-node-red.ps1` 依赖 `pkg\` 中已有可用的 Node.js zip
- `03.install-offline.ps1` 依赖 `pkg\` 中已有 `node-red-3.x.zip` 和 `node-red-4.x.zip`
- `start-nr.bat` 在安装阶段生成
- 如果你指定了 `-InstallRoot`，生成的 `start-nr.bat` 也会出现在那个目录里
- 安装结果是绿色版，整体复制安装目录后即可运行
- 启动时请始终使用 `start-nr.bat <version> <port>`，不要手工调用全局 `node-red`

## 入口脚本

`node-red-multi-install.ps1` 是 `03.install-offline.ps1` 的一个薄封装，参数会直接透传。

如果你只想记住一个安装入口，也可以这样用:

```powershell
.\node-red-multi-install.ps1 -Install
```
