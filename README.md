[English](#english) | [中文](#chinese)

# FPGAFly

<a id="english"></a>
## English

FPGAFly simulates the complete, 166,700-neuron fruit-fly central nervous system connectome (MaleCNS) spiking network on the Sipeed Tang Mega 138K Pro.
The input consists of MNIST grayscale images downsampled from 28×28 to 16×16, with 256 bytes per frame. Each frame corresponds to a 1,000-step simulation window.
The FPGA converts pixel brightness into spike density encoding.
Black produces no spikes, while white produces up to 100 spikes over 1,000 time steps (0.1 ms per step), and classification is performed via a linear readout of the total spike counts.

On the 10,000-image MNIST test set, the first window after warm-up achieves 86.91% accuracy (8,691 / 10,000).
The core runs at 80 MHz and DDR3 at 320 MHz. The implementation uses 270 BSRAMs, 39,035 LUTs, and 48,931 registers.

### 1. Hardware and software

| Item | Configuration |
| --- | --- |
| Board | Sipeed Tang Mega 138K Pro, with onboard DDR3 and JTAG |
| FPGA | GW5AST-LV138FPG676AC1/I0, Rev C |
| Build IDE | Gowin V1.9.12.03 x64 (build 86715) |
| Programmer | Gowin Programmer V1.9.12.02 SP2 x64 (build 2654) |
| Host | Windows x64, Python 3.14.4 (64-bit), FTDI D2XX driver |
| Simulation | WSL Ubuntu 22.04, Python 3.10.12, Verilator 4.038, C++17 compiler, make |

This branch targets the Rev C Tang Mega 138K Pro board. If you are using a Rev B board, please switch to the `main` branch. Connect the board's JTAG USB port to the Windows host. The DDR IP and pin constraints are included in the repository.

This branch includes minor RTL changes to address timing issues caused by the device revision change.

### 2. Get the project and data

Open PowerShell in the project directory (use a directory path without spaces). Run all commands from this directory.

```powershell
python -B tools/data.py restore
```

This restores the packaged data and firmware into the workspace:

- `data/model/`: connection graph, descriptors, readout weights, and spike mapping
- `data/reference/`: shared initial states and queues, six-frame references, and continuous-window references
- `data/input.bin`, `data/test_labels.u8`, `data/test_scores.i64`: preprocessed inputs and first-window accuracy reference
- `build/revc_02/`: restored bitstream, synthesis netlist, and copies of the native synthesis/P&R/timing reports

The prebuilt bitstream and netlist archive is stored at `firmware/bitstream.zip`. Final native reports are provided in `reports/`; restoration copies them to the corresponding build directories.

The six reference frames correspond to input indices 0, 1, 2, 3, 10000, and 10001. `data/reference/states.u64` stores their six blocks of 166,700 state records in that order, matching the order of the reference class scores and activity counters.

To verify the first-window accuracy reference:

```powershell
python -B tools/data.py accuracy
```

The release already includes the preprocessed inputs. If you want to reproduce the preprocessing from the raw MNIST dataset, run:

```powershell
python -B tools/data.py mnist
```

This downloads the raw MNIST files and downsamples the images from 28×28 to 16×16, writing `data/input.bin` and `data/test_labels.u8`.

### 3. Functional simulation

Install the required packages in WSL Ubuntu 22.04:

```bash
sudo apt update
sudo apt install python3 verilator build-essential
```

Run the simulation from PowerShell at the repository root:

```powershell
$windowsRoot = (Get-Location).Path.Replace('\', '/')
$linuxRoot = (wsl -d Ubuntu-22.04 -- wslpath -a "$windowsRoot").Trim()
wsl -d Ubuntu-22.04 --cd "$linuxRoot" -- python3 -B tools/verify.py
```

The simulation runs four ordinary frames and two peak-load frames. Each frame verifies all 166,700 neuron states and spike counts, class scores, and activity counters against the reference data, and must finish within 8,000,000 cycles. Logs are saved under `results/verification/`.

### 4. Build from source

Set your Gowin installation paths in PowerShell and run the build:

```powershell
$ide = "C:/Gowin/Gowin_V1.9.12.03_x64/IDE"
$programmer = "C:/Gowin/Gowin_V1.9.12.02_SP2_x64/Programmer/bin/programmer_cli.exe"
python -B tools/build.py --name mnist16 --tool-bin "$ide/bin"
```

The public license server used for this project is `106.55.34.119:10559`.

By default, the build enables resource replication and uses maximum fanout 64, placement option 3, routing option 2, and `route_maxfan` 23. `rtl/files.f` lists the RTL source files. The build script generates `build/mnist16.tcl`, runs the Gowin toolchain, verifies the native reports, and outputs the project, bitstream, netlist, and reports to `build/mnist16/`.

### 5. SRAM programming and hardware acceptance

If you are using the included bitstream, skip Step 4 and set `$ide` and `$programmer` as shown above. Configure the 64-bit D2XX DLL path and list the connected adapters:

```powershell
$env:THEFLY_D2XX = "$ide/bin/Lib/ftd2xx64.dll"
python -B tools/board.py adapters
```

Note the full serial number of JTAG interface A for your board. Next, check the cable types supported by your Programmer and scan the connected cables:

```powershell
& $programmer --help
& $programmer --scan-cables
```

Note that `--cable-index` specifies the cable type in your Programmer version rather than a device index, and must be provided explicitly:

```powershell
$serial = "REPLACE_WITH_YOUR_INTERFACE_A_SERIAL"
$cableIndex = Read-Host "Enter the cable-type index from your Programmer"
$bitstream = "build/revc_02/impl/pnr/revc_02.fs"
# To use your source build from step 4:
# $bitstream = "build/mnist16/impl/pnr/mnist16.fs"
python -B tools/board.py accept --bitstream "$bitstream" --serial "$serial" --programmer "$programmer" --cable-index "$cableIndex" --reports-dir results/board_acceptance --state-samples 256
```

This programs the SRAM, uploads and verifies the model, and runs the six reference images once. For each image, it checks all class scores and activity counters, samples 256 neuron states, and verifies that computation finishes within 100 ms. Logs are saved under `results/board_acceptance/`.

With the design and model loaded in SRAM, you can run 200 consecutive windows per image:

```powershell
python -B tools/board.py repeat --serial "$serial" --bitstream "$bitstream" --reports-dir results/repeated_frames --frames 200
```

Across consecutive windows, the network states continue while the window's spike counts and classification scores are reset each time. The test compares every window against its reference and samples 256 neuron states after the 200th window. Logs are saved under `results/repeated_frames/`.

### 6. Project structure and data flow

The main entry points are `data.py` (data unpacking, MNIST preprocessing, accuracy check), `build.py` (FPGA build and report checks), `verify.py` (RTL simulation), and `board.py` (adapter listing, hardware acceptance, continuous test).

| Directory | Contents |
| --- | --- |
| `rtl/board` | Top-level connections, clocks, reset, and DDR interface |
| `rtl/host` | JTAG, command dispatch, bulk upload, and memory access |
| `rtl/core` | Frame control, spike generation, and event queues |
| `rtl/memory`, `rtl/state` | DDR reads, response tags, local state RAM, integration, and event updates |
| `ip`, `constraints` | DDR IP, JTAG primitive declaration, pin assignments, and timing constraints |
| `tests` | Six-frame simulation and required primitive models |
| `tools` | Data unpacking, build scripts, timing checks, and board testing |
| `data` | Packaged model, inputs, and reference results |
| `firmware` | Packed bitstream and netlist archive |
| `build` | Restored firmware and source-build outputs |
| `reports` | Native synthesis, P&R, and timing reports |

At the top level, `thefly_top` connects `host_bridge`, `frame_engine`, and `board_memory`. The host uploads the graph, weights, and images to the FPGA over JTAG. Input spikes drive local neuron state updates, event queues schedule graph-edge reads from DDR, and the linear readout accumulates the ten class scores for the host to read back and verify.

Inside `frame_engine`, `frame_control` manages commands, state transitions, and responses across the processing modules:

- `frame_boot` initializes the input, readout biases, and delay queues. `neuron_loader` decodes initial states and writes full RAM rows.
- `frame_compute` advances time steps. `delay_queue` manages delay slots, while `event_delivery` fetches due events and passes them through `edge_decoder` to the state array.
- `retina_drive` generates input spikes. `spike_rows` buffers row results, `spike_cursor` selects firing neurons, and `spike_scan` scans the spike bitmap.
- `frame_memory` arbitrates DDR accesses and prefetching. `descriptor_cache` caches neuron descriptors and readout coefficients.
- `linear_readout` accumulates class scores, and `state_sample` reads individual neuron states.

### 7. Connectome data sources

The spiking network is built from MaleCNS v1.0, the complete male fruit-fly brain and ventral nerve cord connectome produced by HHMI Janelia, the University of Cambridge, the MRC Laboratory of Molecular Biology, and Google Research. This project uses the released neuron annotations, neurotransmitter predictions, and connection-weight tables.

- [Google Research: A connectomics milestone: Mapping the complete male fruit fly brain](https://research.google/blog/a-connectomics-milestone-mapping-the-complete-male-fruit-fly-brain/)
- [MaleCNS v1.0: original data and downloads](https://male-cns.janelia.org/download/)
- [Sexual dimorphism in the complete Drosophila male central nervous system connectome — Cell](https://doi.org/10.1016/j.cell.2026.08.015)

This project was developed with assistance from Codex.

---

<a id="chinese"></a>
## 中文

FPGAFly 在 Sipeed Tang Mega 138K Pro 上完整模拟了包含 166,700 个神经元的果蝇中枢神经系统连接组（MaleCNS）脉冲网络。
输入为从 28×28 降采样至 16×16 的 MNIST 灰度图，每帧 256 字节；每帧对应一个包含 1,000 个时间步的仿真窗口。
FPGA 将像素亮度转换为脉冲密度编码。
纯黑不发脉冲，纯白在 1,000 个时间步（每步 0.1 ms）内最多产生 100 个脉冲，最后通过对总脉冲计数进行线性读出来完成分类。

在 10,000 张 MNIST 测试集上，模型预热后首个窗口的准确率为 86.91%（8,691 / 10,000）。
内核时钟为 80 MHz，DDR3 时钟为 320 MHz。实现使用了 270 个 BSRAM、39,035 个 LUT 和 48,931 个寄存器。

### 1. 硬件与软件

| 项目 | 配置 |
| --- | --- |
| 开发板 | Sipeed Tang Mega 138K Pro（板载 DDR3 和 JTAG） |
| FPGA | GW5AST-LV138FPG676AC1/I0，Rev C |
| 构建 IDE | Gowin V1.9.12.03 x64（build 86715） |
| 烧录器 | Gowin Programmer V1.9.12.02 SP2 x64（build 2654） |
| 主机 | Windows x64、Python 3.14.4（64 位）、FTDI D2XX 驱动 |
| 仿真 | WSL Ubuntu 22.04、Python 3.10.12、Verilator 4.038、C++17 编译器、make |

当前分支对应 Rev C 的 Tang Mega 138K Pro 开发板。如果使用 Rev B 的板卡，请切换至 `main` 分支。将板卡的 JTAG USB 接口连接至 Windows 主机即可。仓库已包含所需的 DDR IP 和引脚约束。

针对器件版本变化带来的时序问题，本分支对 RTL 做了小幅修改。

### 2. 获取项目与数据

在项目目录下打开 PowerShell（建议使用不含空格的目录路径），后续命令均在该目录下执行：

```powershell
python -B tools/data.py restore
```

该命令会将压缩包中的数据和固件恢复到工作区：

- `data/model/`：连接图、描述符、读出权重和脉冲映射
- `data/reference/`：共用初始状态与队列、六帧参考结果和连续窗口参考结果
- `data/input.bin`、`data/test_labels.u8`、`data/test_scores.i64`：预处理输入、测试标签及首个窗口的分类参考分数
- `build/revc_02/`：恢复后的 bitstream、综合网表及综合/布局布线/时序报告副本

`firmware/bitstream.zip` 是预构建 bitstream 和网表压缩包。最终原生报告随仓库保存在 `reports/` 中，恢复时复制到对应构建目录。

六个参考帧对应的输入下标依次为 0、1、2、3、10000 和 10001。`data/reference/states.u64` 按此顺序保存了六组（每组 166,700 条）神经元状态记录，分类分数和活动计数也按相同顺序排列。

核对首个窗口参考结果的分类准确率：

```powershell
python -B tools/data.py accuracy
```

数据包已包含处理好的输入文件。如需从原始 MNIST 数据集重新生成预处理输入，可运行：

```powershell
python -B tools/data.py mnist
```

该命令会自动下载原始 MNIST 文件，将图片从 28×28 降采样至 16×16，并生成 `data/input.bin` 和 `data/test_labels.u8`。

### 3. 功能仿真

在 WSL Ubuntu 22.04 中安装依赖工具：

```bash
sudo apt update
sudo apt install python3 verilator build-essential
```

在项目根目录的 PowerShell 中运行仿真：

```powershell
$windowsRoot = (Get-Location).Path.Replace('\', '/')
$linuxRoot = (wsl -d Ubuntu-22.04 -- wslpath -a "$windowsRoot").Trim()
wsl -d Ubuntu-22.04 --cd "$linuxRoot" -- python3 -B tools/verify.py
```

仿真会运行 4 个普通帧和 2 个峰值帧，在每帧中比对全部 166,700 个神经元的状态、脉冲计数、类别分数和活动计数，并验证计算在 8,000,000 个周期内完成。仿真日志保存在 `results/verification/` 下。

### 4. 从源码构建

在 PowerShell 中设置 Gowin 工具链的实际安装路径并执行构建：

```powershell
$ide = "C:/Gowin/Gowin_V1.9.12.03_x64/IDE"
$programmer = "C:/Gowin/Gowin_V1.9.12.02_SP2_x64/Programmer/bin/programmer_cli.exe"
python -B tools/build.py --name mnist16 --tool-bin "$ide/bin"
```

本项目使用的公开许可服务器为 `106.55.34.119:10559`。

构建默认启用资源复制，最大扇出设为 64，布局选项为 3，布线选项为 2，`route_maxfan` 为 23。`rtl/files.f` 为源文件清单。构建脚本会生成 `build/mnist16.tcl` 并调用 Gowin 完成综合与布局布线，检查原生报告后，将工程、bitstream、网表及报告输出至 `build/mnist16/`。

### 5. SRAM 下载、运行和验收

若直接使用随包提供的固件，可跳过第 4 步，仅按上文设置好 `$ide` 和 `$programmer`。接着配置 64 位 D2XX DLL 路径并列出当前连接的下载器：

```powershell
$env:THEFLY_D2XX = "$ide/bin/Lib/ftd2xx64.dll"
python -B tools/board.py adapters
```

记录所接板卡 JTAG 接口 A 的完整序列号（`serial`）。随后查看本机 Programmer 支持的线缆类型并扫描设备：

```powershell
& $programmer --help
& $programmer --scan-cables
```

注意 `--cable-index` 表示 Programmer 中的线缆类型编号而非设备序号，运行时需显式指定：

```powershell
$serial = "填写刚刚枚举得到的接口 A 序列号"
$cableIndex = Read-Host "输入本机 Programmer 对应线缆类型的 cable-index"
$bitstream = "build/revc_02/impl/pnr/revc_02.fs"
# 如需使用第 4 步自行构建的 bitstream：
# $bitstream = "build/mnist16/impl/pnr/mnist16.fs"
python -B tools/board.py accept --bitstream "$bitstream" --serial "$serial" --programmer "$programmer" --cable-index "$cableIndex" --reports-dir results/board_acceptance --state-samples 256
```

验收脚本会将固件下载到 SRAM，上传并抽样核对模型，随后依次运行六张参考图片。每张图片都会比对全部类别分数和活动计数，抽样检查 256 个神经元状态，并验证计算耗时不超过 100 ms。相关日志保存在 `results/board_acceptance/` 下。

当 SRAM 固件与模型加载完成后，可对每张图片连续运行 200 个窗口：

```powershell
python -B tools/board.py repeat --serial "$serial" --bitstream "$bitstream" --reports-dir results/repeated_frames --frames 200
```

在连续窗口测试中，网络状态跨窗口延续，而每个窗口的脉冲计数和分类分数会重新统计。测试会逐个窗口核对参考结果，并在第 200 个窗口结束后抽样检查 256 个神经元状态。相关日志保存在 `results/repeated_frames/` 下。

### 6. 项目结构和数据流

项目主要提供四个脚本入口：`data.py`（数据恢复、MNIST 预处理、准确率核对）、`build.py`（源码构建与报告检查）、`verify.py`（功能仿真）和 `board.py`（下载器枚举、上板验收、连续窗口测试）。

| 目录 | 内容 |
| --- | --- |
| `rtl/board` | 顶层连接、时钟与复位、DDR 物理接口 |
| `rtl/host` | JTAG 通信、命令分发、批量上传、内存访问 |
| `rtl/core` | 帧控制、脉冲生成、事件队列 |
| `rtl/memory`、`rtl/state` | DDR 读取、响应标签、局部状态 RAM、积分及事件更新 |
| `ip`、`constraints` | DDR IP、JTAG 原语声明、引脚及时序约束 |
| `tests` | 六帧功能仿真及所需原语模型 |
| `tools` | 数据恢复、构建、时序检查、上板测试脚本 |
| `data` | 模型数据、输入与参考结果 |
| `firmware` | bitstream 和综合网表压缩包 |
| `build` | 恢复后的固件及源码构建产物 |
| `reports` | 综合、布局布线和时序原生报告 |

顶层模块 `thefly_top` 连接了 `host_bridge`、`frame_engine` 和 `board_memory`。主机通过 JTAG 将图结构、权重和图片上传至 FPGA。输入脉冲驱动局部神经元状态更新，事件队列调度 DDR 中的图边读取，线性读出模块累加十个类别的分数，最后由主机读回并与参考值比对。

在 `frame_engine` 内部，由 `frame_control` 统一管理命令解析、阶段切换和结果回复，并协调各处理模块工作：

- `frame_boot` 负责准备输入、读出偏置和延迟队列，`neuron_loader` 解码初始神经元状态并整行写入 RAM。
- `frame_compute` 负责推进时间步，`delay_queue` 管理延迟槽，`event_delivery` 读取到期事件并通过 `edge_decoder` 送入状态阵列。
- `retina_drive` 产生输入脉冲，`spike_rows` 缓存行结果，`spike_cursor` 选出触发脉冲的神经元，`spike_scan` 扫描脉冲位图。
- `frame_memory` 仲裁 DDR 命令与数据预取，`descriptor_cache` 缓存神经元描述符及读出系数。
- `linear_readout` 累加分类分数，`state_sample` 用于读取单个神经元状态。

### 7. 连接组数据来源

本项目构建的脉冲网络基于 MaleCNS v1.0 雄性果蝇脑及腹神经索连接组，该数据集由 HHMI Janelia、剑桥大学、MRC 分子生物学实验室和 Google Research 合作完成。项目使用了其中公开发布的神经元注释、神经递质预测和连接权重表。

- [Google Research：A connectomics milestone: Mapping the complete male fruit fly brain](https://research.google/blog/a-connectomics-milestone-mapping-the-complete-male-fruit-fly-brain/)
- [MaleCNS v1.0：原始数据与下载](https://male-cns.janelia.org/download/)
- [相关论文：Sexual dimorphism in the complete Drosophila male central nervous system connectome — Cell](https://doi.org/10.1016/j.cell.2026.08.015)

本项目使用 Codex 协助开发。