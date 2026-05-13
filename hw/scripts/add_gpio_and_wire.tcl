# Run AFTER re-packaging riscv_top IP to v1.1 with 3 new ports.
# Run in Vivado Tcl Console with kria_soc.bd open.

# ---- 1. Refresh IP catalog + upgrade riscv_top_0 ---------------------------
update_ip_catalog -rebuild
upgrade_bd_cells [get_bd_cells riscv_top_0]
puts "[INFO] riscv_top_0 upgraded — check it now has fetch_enable_i, irq_conv_cnn_i, core_sleep_o"

# ---- 2. Add axi_gpio_0 -----------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {1}      \
    CONFIG.C_GPIO2_WIDTH {1}     \
    CONFIG.C_IS_DUAL {1}         \
    CONFIG.C_ALL_OUTPUTS {1}     \
    CONFIG.C_ALL_INPUTS_2 {1}    \
] [get_bd_cells axi_gpio_0]
puts "[INFO] axi_gpio_0 added (ch1=1-bit output, ch2=1-bit input)"

# ---- 3. Wire external nets -------------------------------------------------
# (a) GPIO ch1 (output) → riscv_top_0.fetch_enable_i
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] \
               [get_bd_pins riscv_top_0/fetch_enable_i]

# (b) riscv_top_0.core_sleep_o → GPIO ch2 (input)
connect_bd_net [get_bd_pins riscv_top_0/core_sleep_o] \
               [get_bd_pins axi_gpio_0/gpio2_io_i]

# (c) conv_cnn_0.irq → riscv_top_0.irq_conv_cnn_i
connect_bd_net [get_bd_pins conv_cnn_0/irq] \
               [get_bd_pins riscv_top_0/irq_conv_cnn_i]

puts "[INFO] 3 external nets wired:"
puts "       axi_gpio_0/gpio_io_o[0]  -> riscv_top_0/fetch_enable_i"
puts "       riscv_top_0/core_sleep_o -> axi_gpio_0/gpio2_io_i[0]"
puts "       conv_cnn_0/irq           -> riscv_top_0/irq_conv_cnn_i"

# ---- 4. Connect GPIO S_AXI clock + reset (auto-route S_AXI via smartconnect)
# (Use 'Run Connection Automation' in GUI for axi_gpio_0/S_AXI → HPM1_FPD)

save_bd_design
puts ""
puts "===================================================================="
puts " NEXT IN GUI:"
puts "===================================================================="
puts " 1. Click 'Run Connection Automation' → tick axi_gpio_0/S_AXI"
puts "      → route via smartconnect_1 (HPM1_FPD path)"
puts " 2. Address Editor:"
puts "      axi_gpio_0/S_AXI/Reg → 0xB002_0000, range 64K"
puts "    Verify existing entries:"
puts "      axi_dma_0/S_AXI_LITE     → 0xB000_0000  64K"
puts "      conv_cnn_0/S00_AXI       → 0xB001_0000  64K"
puts "      axi_bram_ctrl_2/S_AXI    → 0xA000_0000  64K   (via HPM0)"
puts "      axi_bram_ctrl_3/S_AXI    → 0xB004_0000  256K  (via HPM1)"
puts "    Under axi_dma_0/Data_MM2S and Data_S2MM, RIGHT-CLICK and EXCLUDE:"
puts "      axi_bram_ctrl_1/S_AXI"
puts "      axi_bram_ctrl_3/S_AXI"
puts " 3. Validate Design (F6)"
puts " 4. Sources → kria_soc_wrapper → Reset+Generate Output Products"
puts " 5. Generate Bitstream"
puts "===================================================================="
