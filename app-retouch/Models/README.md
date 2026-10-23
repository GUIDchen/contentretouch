# 人脸解析模型（第三方，MIT）

- 文件：`FaceParsing.mlmodel`（50.7 MB）
- 来源：Hugging Face 上的 **mlboydaisuke/Face-Parsing-CoreML**（Core ML 格式，省掉自己转换）
  - 仓库标记 license: mit；上游算法是 **BiSeNet face-parsing**（zllrunning/face-parsing.PyTorch，MIT）
  - 本机实测：编译 0.2 s，512×512 推理 **21 ms**，输出 `argmax_out`（每像素类别）
- 类别表（CelebAMask-HQ 顺序，实测在真实人像上分布合理）：
  0 背景 · **1 皮肤** · 2/3 眉 · 4/5 眼 · 6 眼镜 · 7/8 耳 · 9 耳饰 · 10 鼻 ·
  11 嘴内 · 12/13 唇 · **14 脖子** · 15 颈饰 · 16 衣服 · **17 头发** · 18 帽子
- 实测类别占比（一张正面人像）：背景 34.2%、皮肤 29.9%、头发 17.6%、脖子 10.4%、鼻 3.5%、唇 1.9%、眼 0.8%、眉 1.0%

## 用途

给「皮肤掩膜」用：现在的肤色阈值在 490px 的大脸上能用、88px 的小脸上就不行（实测眼睛处 0.65、
脸颊 0.28），换成解析出来的类别图之后，皮肤/眼睛/头发是**语义分割**的结果，不再靠颜色猜。

## 体积与替代

- 模型 50 MB：安装包会从 1.6 MB 涨到 ~50 MB（用户已确认接受）。
## 量化瘦身（本轮做了）

用 coremltools 9.0 把原模型（**neuralNetwork 类型**）做 8bit 线性量化：

| 版本 | 体积 | 与原模型逐像素一致率 | 结论 |
| --- | --- | --- | --- |
| 原始 | 50.7 MB | — | 留档在 /tmp/faceparse/FaceParsing_original.mlmodel |
| **8bit** | **12.7 MB** | 人像 **99.52%**、婚礼 **98.60%** | **已换用这个** |
| 4bit | 6.4 MB | 人像 88.19%、婚礼 45.31% | 掉太多，不用 |

关键类别占比几乎不变（人像图：皮肤 29.7% → 29.5%，唇 1.84% → 1.84%，眼 0.78% → 0.78%），
推理耗时不变（35~40 ms）。换用后 coretest 里五项解析相关断言的数字一字未变。

复现（本机 pip 默认指向的镜像不通，必须显式指定官方源）：

```sh
python3 -m venv venv
./venv/bin/pip install --index-url https://pypi.org/simple coremltools numpy
./venv/bin/python - <<'EOF'
import coremltools as ct
from coremltools.models.neural_network import quantization_utils
m = ct.models.MLModel('FaceParsing.mlmodel')
quantization_utils.quantize_weights(m, nbits=8).save('FaceParsing_8bit.mlmodel')
EOF
```

注意：`coremltools.optimize.coreml` 那套新 API 只支持 mlprogram 类型，这个模型是 neuralNetwork 类型，
必须用老 API `quantization_utils.quantize_weights`（报错信息里也这么提示）。

## 体积与替代

- 模型 12.7 MB（8bit 量化后）：安装包从 1.6 MB 涨到 **~14 MB**。
- **没有模型也能跑**：核心里的皮肤掩膜是「有解析结果就用解析、没有就退回肤色阈值」，
  所以命令行/精简分发不会因为缺模型而报错。
- 想再瘦：换更小的分割网络，或做 palettization（4bit 实测掉太多，不划算）。
