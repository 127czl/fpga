# 编译、烧录与恢复说明

## 1. 环境

| 项目 | 要求 |
|---|---|
| 操作系统 | Windows 10/11 64-bit |
| Efinity | 2026.1.132 |
| 器件 | Titanium Ti60F225 |
| 时序模型 | C4 |
| 顶层 | `example_top` |
| 位流 | `bitstream/Ti60_v102clear_Competition.bit` |

默认安装目录：

```text
C:\Efinity\2026.1
```

如果安装在其他位置，在执行脚本前设置：

```bat
set EFINITY_HOME=D:\Efinity\2026.1
```

## 2. 直接烧录已提交位流

推荐使用 Efinity GUI Programmer：

1. 启动 Efinity Programmer。
2. 选择 JTAG 模式。
3. 添加 `bitstream/Ti60_v102clear_Competition.bit`。
4. 连接下载器，点击 Program。

也可先完整编译，再运行：

```bat
scripts\program_jtag.bat
```

该命令调用 Efinity 的 `program` flow，实际能否成功取决于板子是否上电、
JTAG 下载器是否被识别，以及工程是否已经生成对应位流。

## 3. 重新编译

在工程根目录运行：

```bat
scripts\compile.bat
```

默认输出：

```text
build_out/
build_work/
```

如果只需要生成位流、不保留临时目录，可在编译完成后删除 `build_work`，
但建议保留 `build_out` 中的最终时序报告和位流。

## 4. 手工命令行流程

### 4.1 综合与完整 compile flow

```bat
C:\Efinity\2026.1\bin\efx_run.bat Ti60_Demo.xml --flow compile --output_dir build_out --work_dir build_work
```

### 4.2 JTAG 编程

```bat
C:\Efinity\2026.1\bin\efx_run.bat Ti60_Demo.xml --flow program --pgm_opts mode=jtag
```

### 4.3 仅生成 bit/bit.bin

如果已经完成综合和布局布线，可执行：

```bat
C:\Efinity\2026.1\bin\efx_run.bat --prj -f pgm --output_dir build_out --work_dir build_work Ti60_Demo
```

## 5. 结果检查

编译后重点检查：

```text
build_out/Ti60_Demo.timing.rpt
build_out/Ti60_Demo.place.rpt
build_out/Ti60_Demo.res.csv
build_out/Ti60_Demo.bit
build_out/Ti60_Demo.bit.bin
```

最终时序必须是：

```text
WNS >= 0
WHS >= 0
```

当前归档结果的 WNS 为 `+0.085ns`，WHS 为 `+0.026ns`。
修改 RTL 后不要用综合结果代替最终布线后时序结果。

说明：Efinity 的布局布线可能因输出路径和工具内部状态产生不同结果，因此
重新编译不保证 `.bit` 逐字节相同。应以 Logic 源文件、约束、最终时序报告和
实板行为为准，而不是只比较位流哈希。本包保留的是 v102 阶段已验证位流。

## 6. 文件校验

在工程根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify_release.ps1
```

如只想手工检查正式位流：

```powershell
Get-FileHash bitstream\Ti60_v102clear_Competition.bit -Algorithm SHA256
Get-FileHash bitstream\Ti60_v102clear_Competition.bit.bin -Algorithm SHA256
```

期望值：

```text
Ti60_v102clear_Competition.bit
E526F4B99264D6E89633EB203F34C4B69329D4FD7D7BA87EDD06C01668D33094

Ti60_v102clear_Competition.bit.bin
B6C0AB46D579C1E4F00FF4B88B7D017A5321C878B0D61ABA66DD7539B2C6FFC9
```

## 7. 发布包恢复

如果只拿到了压缩包：

1. 完整解压到不含特殊权限限制的本地目录。
2. 不要把 `src/`、`ip/`、`pri/` 分开移动，`Ti60_Demo.xml` 使用相对路径引用它们。
3. 直接烧录 `bitstream/Ti60_v102clear_Competition.bit` 可复现本次提交。
4. 需要修改时，用 Efinity 打开 `Ti60_Demo.xml`，不要单独打开某个源文件。
5. 编译并重新运行 `scripts/verify_release.ps1`，再对外发布。

