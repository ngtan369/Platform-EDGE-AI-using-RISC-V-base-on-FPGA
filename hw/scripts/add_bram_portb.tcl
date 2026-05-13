# Add Port B BRAM controllers so ARM can access I-BRAM + D-BRAM directly.
# Run in Vivado Tcl Console after opening vivado_pj.xpr and kria_soc.bd:
#   source ../scripts/add_bram_portb.tcl
#
# After this script: Validate Design, Generate Output Products, Generate Bitstream.

set bd_name [current_bd_design]
puts "[INFO] Working on BD: $bd_name"

# ---- 1. Set blk_mem_gen_1 / blk_mem_gen_2 to True Dual Port RAM -------------
foreach mem {blk_mem_gen_1 blk_mem_gen_2} {
    set inst [get_bd_cells $mem]
    if {$inst eq ""} { error "Cell $mem not found in BD" }
    set_property -dict [list \
        CONFIG.Memory_Type {True_Dual_Port_RAM} \
        CONFIG.Use_RSTB_Pin {false} \
        CONFIG.Port_B_Clock {100} \
        CONFIG.Port_B_Write_Rate {50} \
        CONFIG.Port_B_Enable_Rate {100} \
    ] $inst
    puts "[INFO] $mem → True Dual Port RAM"
}

# ---- 2. Instantiate axi_bram_ctrl_2 (I-BRAM Port B, ARM via HPM0_FPD) ------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_2
set_property CONFIG.SINGLE_PORT_BRAM {1} [get_bd_cells axi_bram_ctrl_2]
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_2/BRAM_PORTA] \
                    [get_bd_intf_pins blk_mem_gen_2/BRAM_PORTB]
# Wire clock + reset (assume PS pl_clk0 and rstgen)
set ps_clk    [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]
set ps_rstn   [get_bd_pins */peripheral_aresetn]
connect_bd_net $ps_clk [get_bd_pins axi_bram_ctrl_2/s_axi_aclk]
puts "[INFO] axi_bram_ctrl_2 added, BRAM_PORTA→blk_mem_gen_2.BRAM_PORTB"

# ---- 3. Instantiate axi_bram_ctrl_3 (D-BRAM Port B, ARM via HPM1_FPD) ------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_3
set_property CONFIG.SINGLE_PORT_BRAM {1} [get_bd_cells axi_bram_ctrl_3]
connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_3/BRAM_PORTA] \
                    [get_bd_intf_pins blk_mem_gen_1/BRAM_PORTB]
connect_bd_net $ps_clk [get_bd_pins axi_bram_ctrl_3/s_axi_aclk]
puts "[INFO] axi_bram_ctrl_3 added, BRAM_PORTA→blk_mem_gen_1.BRAM_PORTB"

puts ""
puts "===================================================================="
puts " NEXT STEPS (manual GUI, ~5 min):"
puts "===================================================================="
puts " 1. Click 'Run Connection Automation' → select:"
puts "      axi_bram_ctrl_2/S_AXI  →  PS M_AXI_HPM0_FPD"
puts "      axi_bram_ctrl_3/S_AXI  →  PS M_AXI_HPM1_FPD (or smartconnect_1)"
puts " 2. Open Address Editor (Window → Address Editor):"
puts "      axi_bram_ctrl_2/S_AXI/Mem0  →  offset 0xA000_0000, range 64K"
puts "      axi_bram_ctrl_3/S_AXI/Mem0  →  offset 0xB004_0000, range 256K"
puts " 3. In Address Editor, under axi_dma_0/Data_MM2S and Data_S2MM:"
puts "      RIGHT-CLICK axi_bram_ctrl_1/S_AXI → Exclude"
puts "      RIGHT-CLICK axi_bram_ctrl_3/S_AXI → Exclude"
puts " 4. Validate Design (F6)"
puts " 5. Sources → kria_soc_wrapper → Reset Output Products → Generate"
puts " 6. Generate Bitstream"
puts "===================================================================="

save_bd_design
