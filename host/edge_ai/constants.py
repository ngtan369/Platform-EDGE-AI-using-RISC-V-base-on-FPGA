"""Memory map + register layout constants — must match firmware/main.c and CLAUDE.md."""

# ---- BRAM controller names (from Vivado block design) ----
BRAM_IBRAM_PORTB = "axi_bram_ctrl_2"
BRAM_DBRAM_PORTB = "axi_bram_ctrl_3"
GPIO_RISCV_RESET = "axi_gpio_0"

# ---- Shared D-BRAM register map (offset from 0xB004_0000 / Port B base) ----
REG_CMD_FROM_ARM   = 0x00
REG_STATUS_TO_ARM  = 0x04
REG_DATASET_ID     = 0x08
REG_RESULT_CLASS   = 0x0C
REG_RESULT_CONF    = 0x10
REG_IFM_PHYS_ADDR  = 0x18
REG_OFM_PHYS_ADDR  = 0x1C
REG_WEIGHT_BASE    = 0x20

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
