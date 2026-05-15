"""High-level handle to the Edge-AI bitstream + RISC-V soft core."""
from __future__ import annotations

import os
import time

from pynq import Overlay, MMIO

from . import constants as C


class EdgeAIOverlay:
    """
    Wraps a pynq.Overlay and exposes:
      - i_bram, d_bram: AXI-BRAM controllers (Port B from ARM side)
      - load_firmware(path):  ARM ghi firmware.bin vào I-BRAM, release reset
      - clear_shared_regs():  zero-out handshake registers
      - kick():               write CMD_START to D-BRAM
      - poll_done(timeout):   spin on REG_STATUS_TO_ARM until DONE
      - set_*_addr() helpers: program physical addresses into shared regs
    """

    def __init__(self, bitstream_path: str):
        if not os.path.exists(bitstream_path):
            raise FileNotFoundError(bitstream_path)
        self.overlay = Overlay(bitstream_path)
        self.i_bram  = getattr(self.overlay, C.BRAM_IBRAM_PORTB)
        self.d_bram  = getattr(self.overlay, C.BRAM_DBRAM_PORTB)
        # PYNQ filters axi_gpio_0 out of ip_dict on this BD topology, so go direct via MMIO.
        # GPIO_DATA bit 0 drives riscv_top_0/fetch_enable_i.
        self._gpio = MMIO(C.GPIO_RISCV_RESET_BASE, 0x10000)
        self._gpio.write(C.GPIO_TRI_OFFSET, 0)   # ensure pin is output

    # ---- firmware load ----
    def clear_shared_regs(self) -> None:
        for off in C.ALL_SHARED_REGS:
            self.d_bram.write(off, 0)

    def load_layer_table(self, table_bin_path: str) -> int:
        """Stream packed layer_desc_t array into D-BRAM Port B at LAYER_TABLE_OFFSET.
        RISC-V firmware reads it via m_axi_data (LAYERS = (layer_desc_t*)0xB0040800).
        Returns bytes written."""
        if not os.path.exists(table_bin_path):
            raise FileNotFoundError(table_bin_path)
        with open(table_bin_path, "rb") as f:
            data = f.read()
        if len(data) % 4:
            data += b"\x00" * (4 - (len(data) % 4))
        for i in range(0, len(data), 4):
            self.d_bram.write(C.LAYER_TABLE_OFFSET + i,
                              int.from_bytes(data[i:i+4], "little"))
        return len(data)

    def halt_riscv(self) -> None:
        """Drive fetch_enable_i=0 to park the core at PC=0.
        CV32E40P fetch_enable is sticky-high once asserted, so this only has
        effect BEFORE the first release (i.e., right after PL reset). Calling
        this after release_riscv_reset() does NOT halt a running core."""
        self._gpio.write(C.GPIO_DATA_OFFSET, 0)

    def load_firmware(self, firmware_bin_path: str, *, release_reset: bool = True) -> int:
        """Stream firmware.bin into I-BRAM Port B at offset 0. Returns bytes written.
        If release_reset=True, pulses fetch_enable_i HIGH after the write so RISC-V
        boots from PC=0 with the freshly-loaded firmware."""
        if not os.path.exists(firmware_bin_path):
            raise FileNotFoundError(firmware_bin_path)
        with open(firmware_bin_path, "rb") as f:
            data = f.read()
        if len(data) % 4:
            data += b"\x00" * (4 - (len(data) % 4))
        self.halt_riscv()
        for i in range(0, len(data), 4):
            self.i_bram.write(i, int.from_bytes(data[i:i+4], "little"))
        if release_reset:
            self.release_riscv_reset()
        return len(data)

    def release_riscv_reset(self) -> None:
        """Pull fetch_enable_i HIGH so RISC-V starts from PC=0.
        After Overlay() download, GPIO defaults to 0 (core parked) — this flips to 1."""
        self._gpio.write(C.GPIO_DATA_OFFSET, 1)

    # ---- shared register helpers ----
    def set_weights_addr(self, phys: int) -> None:
        self.d_bram.write(C.REG_WEIGHT_BASE, phys)

    def set_io_buffers(self, ifm_phys: int, ofm_phys: int) -> None:
        self.d_bram.write(C.REG_IFM_PHYS_ADDR, ifm_phys)
        self.d_bram.write(C.REG_OFM_PHYS_ADDR, ofm_phys)

    def set_dataset_id(self, dataset_id: int) -> None:
        self.d_bram.write(C.REG_DATASET_ID, dataset_id)

    # ---- run / wait ----
    def kick(self) -> None:
        self.d_bram.write(C.REG_CMD_FROM_ARM, C.CMD_START)

    def reset_cmd(self) -> None:
        self.d_bram.write(C.REG_CMD_FROM_ARM, C.CMD_IDLE)

    def read_status(self) -> int:
        return self.d_bram.read(C.REG_STATUS_TO_ARM)

    def poll_done(self,
                  timeout_s: float = C.POLL_TIMEOUT_S,
                  interval_s: float = C.POLL_INTERVAL_S) -> None:
        deadline = time.time() + timeout_s
        while True:
            s = self.read_status()
            if s == C.STATUS_DONE:
                return
            if time.time() > deadline:
                raise TimeoutError(
                    f"RISC-V did not signal DONE within {timeout_s:.1f}s "
                    f"(last status=0x{s:08X})"
                )
            time.sleep(interval_s)

    def read_result(self) -> tuple[int, int]:
        """Return (class_id, confidence_q1_7) from RISC-V (if firmware writes them)."""
        return (self.d_bram.read(C.REG_RESULT_CLASS),
                self.d_bram.read(C.REG_RESULT_CONF))
