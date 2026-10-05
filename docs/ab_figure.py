"""Draw docs/ab-cost.svg from the bulk-discount A/B in the README.

Every run is listed: cost as reported by Claude Code, and whether it passed
the task's verification.
"""

from statistics import median

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import MultipleLocator

RUNS = {  # (campaign, arm): [(cost in USD, passed)], from the README table
    (1, "off"): [(0.3168, True), (0.4490, True), (0.4883, True)],
    (1, "on"): [(0.3571, True), (0.3697, True), (0.4021, True)],
    (2, "off"): [(0.4455, False), (0.4524, True), (0.4864, True)],
    (2, "on"): [(0.4104, True), (0.4154, True), (0.4345, True)],
}
ROWS = {"off": 1.0, "on": 0.0}  # y position of each arm
LABELS = {"off": "without plugin", "on": "with plugin"}
COLORS = {"off": "#6b6b6b", "on": "#2a6fdb"}
OFFSET = {1: 0.09, 2: -0.09}  # campaign 1 just above the arm's line, 2 just below

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.size": 10,
    "svg.fonttype": "none",  # keep text as text, in the page's font
})
fig, ax = plt.subplots(figsize=(6.5, 2.6))

for (campaign, arm), runs in RUNS.items():
    y = ROWS[arm] + OFFSET[campaign]
    for cost, passed in runs:
        filled = campaign == 2
        ax.scatter(cost, y, s=48, zorder=3, linewidths=1.4,
                   color=COLORS[arm] if filled else "white", edgecolors=COLORS[arm])
        if not passed:
            ax.scatter(cost, y, s=110, marker="x", color="#c0392b", linewidths=1.6, zorder=4)
            ax.annotate("failed check", (cost, y), xytext=(-10, 0), textcoords="offset points",
                        ha="right", va="center", fontsize=8, color="#c0392b")

medians = {}
for arm, y in ROWS.items():
    costs = [c for (_, a), runs in RUNS.items() if a == arm for c, _ in runs]
    medians[arm] = median(costs)
    ax.vlines(medians[arm], y - 0.25, y + 0.25, color=COLORS[arm], lw=2.2, zorder=2)
    above = arm == "off"  # labels outside the gap between the rows
    ax.annotate(f"median ${medians[arm]:.3f}", (medians[arm], y + (0.27 if above else -0.27)),
                ha="center", va="bottom" if above else "top", fontsize=8, color=COLORS[arm])

change = medians["on"] / medians["off"] - 1
ax.annotate("", xy=(medians["on"], 0.5), xytext=(medians["off"], 0.5),
            arrowprops={"arrowstyle": "->", "color": "#333333", "lw": 1})
ax.annotate(f"{change:+.0%}".replace("-", "−"), ((medians["on"] + medians["off"]) / 2, 0.53),
            ha="center", va="bottom", fontsize=9, color="#333333")

ax.set_yticks(list(ROWS.values()), [LABELS[a] for a in ROWS])
ax.set_ylim(-0.55, 1.6)
ax.set_xlim(0.30, 0.50)
ax.xaxis.set_major_locator(MultipleLocator(0.05))
ax.xaxis.set_minor_locator(MultipleLocator(0.025))
ax.xaxis.set_major_formatter(lambda x, _: f"${x:.2f}")
ax.set_xlabel("cost of one session (USD)")
ax.tick_params(axis="y", length=0)
ax.spines[["top", "right", "left"]].set_visible(False)
ax.grid(axis="x", which="both", color="#e5e5e5", lw=0.8, zorder=0)
ax.set_axisbelow(True)

handles = [
    Line2D([], [], ls="", marker="o", mfc="white", mec="#333333", label="campaign 1"),
    Line2D([], [], ls="", marker="o", mfc="#333333", mec="#333333", label="campaign 2"),
]
ax.legend(handles=handles, frameon=False, fontsize=8, loc="upper left",
          bbox_to_anchor=(0.0, 1.08), ncol=2)
fig.tight_layout()
fig.savefig("docs/ab-cost.svg")
