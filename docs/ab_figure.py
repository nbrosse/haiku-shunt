"""Draw docs/ab-cost.svg from the bulk-discount A/B in the README.

With 3 reps per arm and campaign, the README's median and range give every run.
"""

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

RUNS = {  # (campaign, arm): costs in USD, from the README table
    (1, "off"): [0.317, 0.449, 0.488],
    (1, "on"): [0.357, 0.370, 0.402],
    (2, "off"): [0.446, 0.452, 0.486],
    (2, "on"): [0.410, 0.415, 0.435],
}
COLORS = {"off": "#7f7f7f", "on": "#1f77b4"}
MARKERS = {1: "o", 2: "s"}

fig, ax = plt.subplots(figsize=(5, 3.2))
for (campaign, arm), costs in RUNS.items():
    x = 0 if arm == "off" else 1
    offsets = [-0.06, 0.0, 0.06] if campaign == 1 else [-0.03, 0.03, 0.09]
    ax.scatter([x + o for o in offsets], costs, color=COLORS[arm],
               marker=MARKERS[campaign], s=40, zorder=3)
for x, arm in enumerate(["off", "on"]):
    pooled = sorted(c for (_, a), cs in RUNS.items() if a == arm for c in cs)
    median = (pooled[2] + pooled[3]) / 2
    ax.hlines(median, x - 0.2, x + 0.2, color=COLORS[arm], lw=2)
    ax.annotate(f"median ${median:.3f}", (x + 0.22, median), va="center", fontsize=8)

ax.set_xticks([0, 1], ["off (no plugin)", "on (plugin)"])
ax.set_xlim(-0.5, 1.8)
ax.set_ylabel("session cost (USD)")
ax.set_title("bulk-discount task, 6 runs per arm (p ≈ 0.065)", fontsize=10)
handles = [Line2D([], [], color="black", marker=m, ls="", label=f"campaign {c}")
           for c, m in MARKERS.items()]
ax.legend(handles=handles, frameon=False, fontsize=8, loc="lower right")
ax.spines[["top", "right"]].set_visible(False)
fig.tight_layout()
fig.savefig("docs/ab-cost.svg")
