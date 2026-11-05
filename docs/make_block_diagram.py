# Draws docs/block_diagram.png: the chip as a user sees it (host port, three engines, pin mux, input filter, pins).
# Run from the repository root: python docs/make_block_diagram.py
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

INK = "#1f2933"
HOST = "#dbe9f6"
PORT = "#c6dcef"
ENG = "#fbe3c4"
MUX = "#d5ecd4"
PIN = "#e4e7eb"

fig, ax = plt.subplots(figsize=(16, 8.6), dpi=110)
fig.subplots_adjust(left=0.01, right=0.99, bottom=0.01, top=0.99)
ax.set_xlim(0, 16)
ax.set_ylim(0.1, 9.4)
ax.axis("off")
fig.patch.set_facecolor("white")


def box(x0, y0, x1, y1, fill, title, body="", tsize=13, bsize=10.5):
    ax.add_patch(FancyBboxPatch((x0, y0), x1 - x0, y1 - y0, boxstyle="round,pad=0.02,rounding_size=0.12",
                                fc=fill, ec=INK, lw=1.4))
    cx = (x0 + x1) / 2
    if body:
        ax.text(cx, y1 - 0.28, title, ha="center", va="top", fontsize=tsize, fontweight="bold", color=INK)
        ax.text(cx, y1 - 0.75, body, ha="center", va="top", fontsize=bsize, color=INK, linespacing=1.45)
    else:
        ax.text(cx, (y0 + y1) / 2, title, ha="center", va="center", fontsize=tsize, fontweight="bold", color=INK)


def arrow(x0, y0, x1, y1, both=False):
    ax.annotate("", xy=(x1, y1), xytext=(x0, y0),
                arrowprops=dict(arrowstyle="<|-|>" if both else "-|>", color=INK, lw=1.4, shrinkA=0, shrinkB=0,
                                mutation_scale=14))


ax.text(8, 9.1, "tt_um_gosforth_protocol_emu: protocol emulator, three engines, 50 MHz", ha="center", va="center",
        fontsize=15, fontweight="bold", color=INK)

# host microcontroller and host port
box(0.2, 3.6, 2.3, 5.8, HOST, "Host", "RP2040, ESP32,\nPico 2 or any\nSPI master")
box(3.4, 1.0, 6.3, 8.4, PORT, "SPI host port",
    "SPI mode 0, MSB first\nSCK at most clk / 8\n\n16-bit command:\n[15] read  [14:12] engine\n[5:0] register\n\n"
    "Per engine:\nprogram 0x00-0x1F\nsettings 0x20-0x25\nTXFIFO 0x26  RXFIFO 0x27\nSTATUS 0x28\n\n"
    "Chip-wide:\nFILTER 0x29   ID 0x2A", bsize=10)
arrow(2.3, 5.2, 3.4, 5.2)
ax.text(2.85, 5.32, "CS  ui[0]\nSCK ui[1]\nMOSI ui[2]", ha="center", va="bottom", fontsize=9, color=INK)
arrow(3.4, 4.2, 2.3, 4.2)
ax.text(2.85, 4.08, "MISO uo[0]\nIRQ  uo[1]", ha="center", va="top", fontsize=9, color=INK)

# engines
eng_y = [(6.6, 8.2, "Engine A (0)"), (3.9, 5.5, "Engine B (1)"), (1.2, 2.8, "Engine C (2)")]
for y0, y1, name in eng_y:
    box(7.4, y0, 9.7, y1, ENG, name, "32-word program\nruns on its own\nclock divider", bsize=10)
    arrow(6.3, (y0 + y1) / 2, 7.4, (y0 + y1) / 2, both=True)
    arrow(9.7, (y0 + y1) / 2, 10.6, (y0 + y1) / 2, both=True)
ax.text(6.85, 7.25, "program,\nsettings,\nTX FIFO\n4 words,\nRX FIFO\n4 words", ha="center", va="top", fontsize=8.5,
        color=INK)
ax.text(10.15, 7.25, "levels,\ndirections\nout;\ninputs in", ha="center", va="top", fontsize=8.5, color=INK)

# pin mux and input conditioning
box(10.6, 1.0, 12.9, 8.4, MUX, "Pins", "")
ax.texts[-1].set_position((11.75, 8.05))
ax.text(11.75, 7.55, "Out: an engine drives\na pin only where its\ndirection bit is 1.\n\nSeveral engines on\none pin: the lowest\nnumber wins\n(A over B over C).",
        ha="center", va="top", fontsize=10, color=INK, linespacing=1.45)
ax.plot([10.75, 12.75], [4.55, 4.55], color=INK, lw=0.8, ls="--")
ax.text(11.75, 4.35, "In: every input passes\na 2-flip-flop synchroniser\nand the glitch filter\n(FILTER, chip-wide).\n\nEvery engine reads\nevery input.",
        ha="center", va="top", fontsize=10, color=INK, linespacing=1.45)

# chip pins
box(13.9, 6.9, 15.8, 8.4, PIN, "uo[7:2]", "engine pins 8-13\nout only", bsize=10)
box(13.9, 4.1, 15.8, 5.9, PIN, "uio[7:0]", "engine pins 0-7\nin and out\n(open drain by\ndirection)", bsize=10)
box(13.9, 1.0, 15.8, 2.5, PIN, "ui[7:3]", "engine pins 15-19\nin only", bsize=10)
arrow(12.9, 7.65, 13.9, 7.65)
arrow(12.9, 5.0, 13.9, 5.0, both=True)
arrow(13.9, 1.75, 12.9, 1.75)

ax.text(8, 0.45, "Engines read pins 8-13 as 0; pins 14 and 20-31 have no chip pin and read 0.   IRQ is high while any engine's RX FIFO holds a word.",
        ha="center", va="center", fontsize=10, color=INK)

fig.savefig("docs/block_diagram.png", dpi=110, facecolor="white")
print("wrote docs/block_diagram.png")
