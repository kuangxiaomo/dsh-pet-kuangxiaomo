# 关于美术素材：为什么这个仓库里没有立绘

`helper/pet-window.ps1` 需要一张立绘（默认文件名 `assets/DSniang1.png`），
但**这个仓库故意不含它**，原因两条：

1. 我们最初用的那张图来自
   [`dsh-whale-widget`](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)。
   那个仓库的 `PROVENANCE.md` 明确写着：**代码是 MIT，但 `assets/**` 不在 MIT 覆盖范围内**，
   按 as-is 随插件分发、**不授予再许可**。所以我没有权利把它搬到这里再发一次。
2. 那张图是 AI 生成图，原始出处不可考 —— 与其硬给一个站不住的授权，不如不放。

## 那插件还跑得起来吗？

跑得起来。窗口脚本按顺序找图：

1. `%USERPROFILE%\.dsh\profiles\desktop\node_modules\dsh-whale-widget\assets\DSniang1.png`
   （装了 whale-widget 就直接命中）
2. 本插件目录下的 `assets\DSniang1.png`（**你自己放**）

两个都找不到时，窗口照样能开、气泡和输入框都能用，只是立绘位置显示一句
「找不到立绘图，把 DSniang1.png 放到 assets 里」。

## 想换成自己的形象

把任意 PNG 放到 `assets\DSniang1.png`（建议正方形、带透明通道），
或者给脚本传 `-ImagePath "D:\某个图.png"`。

## 许可范围（一句话）

**本仓库的代码按 MIT 许可**（见 [`LICENSE`](LICENSE)）——因为美术素材不在仓库里，
那份 MIT 实际只覆盖代码；你放进 `assets/` 的图，权利归你自己，**不在**这份 MIT 里。
