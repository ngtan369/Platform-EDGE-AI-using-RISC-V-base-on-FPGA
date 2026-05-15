"""Memory map + register layout constants — must match firmware/main.c and CLAUDE.md."""

# ---- BRAM controller names (from Vivado block design) ----
BRAM_IBRAM_PORTB = "axi_bram_ctrl_2"
BRAM_DBRAM_PORTB = "axi_bram_ctrl_3"

# ---- axi_gpio_0 (drives riscv_top_0/fetch_enable_i) — accessed via raw MMIO
# because PYNQ ip_dict filters this IP out on the current BD topology.
GPIO_RISCV_RESET_BASE = 0xB0020000
GPIO_DATA_OFFSET = 0x00     # channel 1 data register
GPIO_TRI_OFFSET  = 0x04     # channel 1 tri-state register (0 = output)

# ---- Shared D-BRAM register map (offset from 0xB004_0000 / Port B base) ----
REG_CMD_FROM_ARM   = 0x00
REG_STATUS_TO_ARM  = 0x04
REG_DATASET_ID     = 0x08
REG_RESULT_CLASS   = 0x0C
REG_RESULT_CONF    = 0x10
REG_IFM_PHYS_ADDR  = 0x18
REG_OFM_PHYS_ADDR  = 0x1C
REG_WEIGHT_BASE    = 0x20
# Layer table region (D-BRAM-resident copy of LAYERS[]). ARM populates before
# CMD_START. Capacity: 5 KB (~128 layers of 40 B each). Must match firmware
# layer_table.h: #define LAYERS ((const layer_desc_t*)0xB0040800u)
LAYER_TABLE_OFFSET = 0x800

ALL_SHARED_REGS = (
    REG_CMD_FROM_ARM, REG_STATUS_TO_ARM, REG_DATASET_ID,
    REG_RESULT_CLASS, REG_RESULT_CONF,
    REG_IFM_PHYS_ADDR, REG_OFM_PHYS_ADDR, REG_WEIGHT_BASE,
)

# ---- Command + status flags ----
CMD_IDLE     = 0x00
CMD_START    = 0x01

STATUS_IDLE  = 0x00
STATUS_BUSY  = 0x01
STATUS_DONE  = 0x02

# ---- Polling defaults ----
POLL_TIMEOUT_S    = 5.0
POLL_INTERVAL_S   = 5e-4
