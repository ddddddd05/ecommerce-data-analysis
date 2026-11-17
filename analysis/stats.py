"""A/B 测试用到的统计方法（只依赖 scipy 的正态分布和卡方分布）。

- 两比例 z 检验：A、B 两组的转化率差异，是真实差异还是随机波动？
  p 值 < 0.05 → 有 95% 的把握认为差异不是偶然（统计显著）。
- 差值的 95% 置信区间：真实差异大概率落在这个范围内；区间不包含 0 才说明有差异。
- 样本比例检验（SRM，Sample Ratio Mismatch）：流量本该五五分，实际偏差太大说明分流有问题，
  这时转化率差异也不可信。
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from scipy.stats import chi2, norm


@dataclass
class ProportionTest:
    rate_a: float
    rate_b: float
    diff: float              # B - A（绝对差，单位：比例）
    relative_lift: float     # (B - A) / A
    ci_low: float            # 差值 95% 置信区间
    ci_high: float
    z: float
    p_value: float

    @property
    def significant(self) -> bool:
        return self.p_value < 0.05


def two_proportion_test(success_a: int, n_a: int, success_b: int, n_b: int,
                        alpha: float = 0.05) -> ProportionTest:
    """双侧两比例 z 检验。检验用合并比例算标准误；置信区间用各自比例算标准误（标准做法）。"""
    if min(n_a, n_b) <= 0:
        raise ValueError("样本量必须大于 0")
    if not (0 <= success_a <= n_a and 0 <= success_b <= n_b):
        raise ValueError("成功数必须在 0 和样本量之间")
    pa, pb = success_a / n_a, success_b / n_b
    pooled = (success_a + success_b) / (n_a + n_b)
    se_pooled = math.sqrt(pooled * (1 - pooled) * (1 / n_a + 1 / n_b))
    z = (pb - pa) / se_pooled if se_pooled > 0 else 0.0
    p_value = 2 * (1 - norm.cdf(abs(z)))
    se = math.sqrt(pa * (1 - pa) / n_a + pb * (1 - pb) / n_b)
    zc = norm.ppf(1 - alpha / 2)
    diff = pb - pa
    return ProportionTest(pa, pb, diff, diff / pa if pa > 0 else float("nan"),
                          diff - zc * se, diff + zc * se, z, p_value)


def required_sample_size(p_a: float, p_b: float, alpha: float = 0.05, power: float = 0.8) -> int:
    """每组需要多少样本，才能以 power（默认 80%）的概率检测出 p_a → p_b 的差异（双侧检验）。

    测试开始前用它定“要跑多久”：样本不够时，即使真的有提升，也大概率测不出来。
    """
    for name, v in (("p_a", p_a), ("p_b", p_b), ("alpha", alpha), ("power", power)):
        if not 0 < v < 1:
            raise ValueError(f"{name} 必须在 0 和 1 之间（不含端点），收到 {v}")
    if p_a == p_b:
        raise ValueError("两个比例相同，无法计算")
    za, zb = norm.ppf(1 - alpha / 2), norm.ppf(power)
    p_bar = (p_a + p_b) / 2
    n = (za * math.sqrt(2 * p_bar * (1 - p_bar)) + zb * math.sqrt(p_a * (1 - p_a) + p_b * (1 - p_b))) ** 2 \
        / (p_b - p_a) ** 2
    return math.ceil(n)


def sample_ratio_test(n_a: int, n_b: int, expected_share_a: float = 0.5) -> float:
    """卡方检验分流比例，返回 p 值。p < 0.001 视为分流异常（业界常用的严格门槛）。"""
    if n_a < 0 or n_b < 0 or n_a + n_b == 0:
        raise ValueError("样本量必须是非负数，且两组合计大于 0")
    if not 0 < expected_share_a < 1:
        raise ValueError(f"expected_share_a 必须在 0 和 1 之间（不含端点），收到 {expected_share_a}")
    total = n_a + n_b
    exp_a, exp_b = total * expected_share_a, total * (1 - expected_share_a)
    stat = (n_a - exp_a) ** 2 / exp_a + (n_b - exp_b) ** 2 / exp_b
    return float(1 - chi2.cdf(stat, df=1))
