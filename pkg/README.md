# pkg 离线包目录

将以下文件放入此目录：

## Node.js 运行时（Windows 64-bit Binary .zip）

| 文件名 | 用途 | 下载地址 |
|:---|:---:|:---|
| `node-v14.21.3-win-x64.zip` | NR3 可选 (Node 14) | https://nodejs.org/dist/v14.21.3/node-v14.21.3-win-x64.zip |
| `node-v16.20.2-win-x64.zip` | NR3 推荐 (Node 16) | https://nodejs.org/dist/v16.20.2/node-v16.20.2-win-x64.zip |
| `node-v18.20.4-win-x64.zip` | NR4 可选 (Node 18) | https://nodejs.org/dist/v18.20.4/node-v18.20.4-win-x64.zip |
| `node-v20.11.1-win-x64.zip` | NR4 可选 (Node 20) | https://nodejs.org/dist/v20.11.1/node-v20.11.1-win-x64.zip |
| `node-v22.3.0-win-x64.zip` | NR4 推荐 (Node 22) | https://nodejs.org/dist/v22.3.0/node-v22.3.0-win-x64.zip |

## Node-RED 预装包（含 node_modules）

| 文件名 | 说明 |
|:---|:---|
| `node-red-3.x.zip` | Node-RED 3.x 完整包（需在联网机器上 `npm install node-red@^3` 后打包） |
| `node-red-4.x.zip` | Node-RED 4.x 完整包（需在联网机器上 `npm install node-red@^4` 后打包） |

### 制作 NR3 包的方法

```powershell
# 在联网机器上执行
mkdir pkg-temp-nr3 && cd pkg-temp-nr3
npm init -y
npm install node-red@^3.1.0
# 打包成 zip
Compress-Archive -Path .\* -DestinationPath node-red-3.x.zip -Force
```

### 制作 NR4 包的方法

```powershell
mkdir pkg-temp-nr4 && cd pkg-temp-nr4
npm init -y
npm install node-red@^4
Compress-Archive -Path .\* -DestinationPath node-red-4.x.zip -Force