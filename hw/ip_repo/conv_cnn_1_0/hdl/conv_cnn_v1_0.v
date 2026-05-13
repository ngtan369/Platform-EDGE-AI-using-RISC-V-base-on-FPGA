// =============================================================================
// conv_cnn_v1_0.v — Top wrapper IP packager (v2.0 datapath)
//
// Lưu ý: file extension giữ .v cho Vivado IP Packager pickup, nhưng instantiate
// SystemVerilog modules (conv_core, controller_fsm, ...) — Vivado mixed-language
// xử lý OK miễn các .sv source nằm trong cùng IP source list.
//
// AXIS data path:
//   S00_AXIS (32-bit) → low 8 bits → conv_core.s_data
//   conv_core.m_data (8-bit) → low 8 bits of M00_AXIS, upper 24 bit pad 0
//
// Cấu hình runtime qua S00_AXI register file (xem conv_cnn_v1_0_S00_AXI.v).
// =============================================================================
`timescale 1 ns / 1 ps

module conv_cnn_v1_0 #(
    // Do not modify the parameters beyond this line

    // Parameters of Axi Slave Bus Interface S00_AXI (BUMPED 4 → 5 cho 8 reg)
    parameter integer C_S00_AXI_DATA_WIDTH  = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH  = 5,

    // Parameters of Axi Slave Bus Interface S00_AXIS
    parameter integer C_S00_AXIS_TDATA_WIDTH = 32,

    // Parameters of Axi Master Bus Interface M00_AXIS
    parameter integer C_M00_AXIS_TDATA_WIDTH = 32,
    parameter integer C_M00_AXIS_START_COUNT = 32
)(
    // User ports
    output wire irq,                                    // done IRQ cho RISC-V/ARM

    // S00_AXI (control/status registers)
    input  wire                              s00_axi_aclk,
    input  wire                              s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
    input  wire [2 : 0]                      s00_axi_awprot,
    input  wire                              s00_axi_awvalid,
    output wire                              s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
    input  wire                              s00_axi_wvalid,
    output wire                              s00_axi_wready,
    output wire [1 : 0]                      s00_axi_bresp,
    output wire                              s00_axi_bvalid,
    input  wire                              s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
    input  wire [2 : 0]                      s00_axi_arprot,
    input  wire                              s00_axi_arvalid,
    output wire                              s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
    output wire [1 : 0]                      s00_axi_rresp,
    output wire                              s00_axi_rvalid,
    input  wire                              s00_axi_rready,

    // S00_AXIS — IFM + weight stream in
    input  wire                                  s00_axis_aclk,
    input  wire                                  s00_axis_aresetn,
    output wire                                  s00_axis_tready,
    input  wire [C_S00_AXIS_TDATA_WIDTH-1 : 0]   s00_axis_tdata,
    input  wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
    input  wire                                  s00_axis_tlast,
    input  wire                                  s00_axis_tvalid,

    // M00_AXIS — OFM stream out
    input  wire                                  m00_axis_aclk,
    input  wire                                  m00_axis_aresetn,
    output wire                                  m00_axis_tvalid,
    output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0]   m00_axis_tdata,
    output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
    output wire                                  m00_axis_tlast,
    input  wire                                  m00_axis_tready
);

    // -----------------------------------------------------------------------
    // Internal config wires from S00_AXI register file → conv_core
    // -----------------------------------------------------------------------
    wire [15:0] cfg_width;
    wire [15:0] cfg_height;
    wire        cfg_start;
    wire        cfg_pool_en;
    wire        cfg_mode_load;
    wire        cfg_has_relu;
    wire        cfg_done;
    wire [15:0] cfg_num_cin;
    wire [15:0] cfg_num_cout;
    wire [30:0] cfg_M_q31;
    wire [5:0]  cfg_shift;
    wire [7:0]  cfg_output_zp;

    // -----------------------------------------------------------------------
    // S00_AXI control/status register file
    // -----------------------------------------------------------------------
    conv_cnn_v1_0_S00_AXI #(
        .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
    ) u_axi_lite (
        .S_AXI_ACLK    (s00_axi_aclk),
        .S_AXI_ARESETN (s00_axi_aresetn),
        .S_AXI_AWADDR  (s00_axi_awaddr),
        .S_AXI_AWPROT  (s00_axi_awprot),
        .S_AXI_AWVALID (s00_axi_awvalid),
        .S_AXI_AWREADY (s00_axi_awready),
        .S_AXI_WDATA   (s00_axi_wdata),
        .S_AXI_WSTRB   (s00_axi_wstrb),
        .S_AXI_WVALID  (s00_axi_wvalid),
        .S_AXI_WREADY  (s00_axi_wready),
        .S_AXI_BRESP   (s00_axi_bresp),
        .S_AXI_BVALID  (s00_axi_bvalid),
        .S_AXI_BREADY  (s00_axi_bready),
        .S_AXI_ARADDR  (s00_axi_araddr),
        .S_AXI_ARPROT  (s00_axi_arprot),
        .S_AXI_ARVALID (s00_axi_arvalid),
        .S_AXI_ARREADY (s00_axi_arready),
        .S_AXI_RDATA   (s00_axi_rdata),
        .S_AXI_RRESP   (s00_axi_rresp),
        .S_AXI_RVALID  (s00_axi_rvalid),
        .S_AXI_RREADY  (s00_axi_rready),

        // User ports
        .out_width     (cfg_width),
        .out_height    (cfg_height),
        .out_start     (cfg_start),
        .out_pool_en   (cfg_pool_en),
        .out_mode_load (cfg_mode_load),
        .out_has_relu  (cfg_has_relu),
        .in_done       (cfg_done),
        .out_num_cin   (cfg_num_cin),
        .out_num_cout  (cfg_num_cout),
        .out_M_q31     (cfg_M_q31),
        .out_shift     (cfg_shift),
        .out_output_zp (cfg_output_zp)
    );

    // -----------------------------------------------------------------------
    // conv_core (v2.0 SV datapath top)
    //   AXIS s_data = S00_AXIS tdata low byte (upper 24 bits ignored — pad)
    //   AXIS m_data = M00_AXIS tdata low byte (upper 24 bits = 0)
    //   Use s00_axi_aclk làm clock chính (AXIS clocks giả định cùng domain).
    // -----------------------------------------------------------------------
    wire        cc_s_ready;
    wire        cc_m_valid;
    wire [7:0]  cc_m_data;

    conv_core u_core (
        .clk           (s00_axi_aclk),
        .rst_n         (s00_axi_aresetn),

        // Configuration (slice down về widths package: 8/6/6/31/6/8)
        .cfg_start     (cfg_start),
        .cfg_mode_load (cfg_mode_load),
        .cfg_width     (cfg_width[7:0]),     // WIDTH_ADDR_W = 8 (clog2(256))
        .cfg_height    (cfg_height[7:0]),
        .cfg_num_cin   (cfg_num_cin[5:0]),   // CIN_ADDR_W = 6 (clog2(64))
        .cfg_num_cout  (cfg_num_cout[5:0]),
        .cfg_pool_en   (cfg_pool_en),
        .cfg_M_q31     (cfg_M_q31),
        .cfg_shift     (cfg_shift),
        .cfg_output_zp ($signed(cfg_output_zp)),
        .cfg_has_relu  (cfg_has_relu),

        // AXIS in (1 byte/sample từ low byte của tdata)
        .s_data        (s00_axis_tdata[7:0]),
        .s_valid       (s00_axis_tvalid),
        .s_ready       (cc_s_ready),

        // AXIS out
        .m_data        (cc_m_data),
        .m_valid       (cc_m_valid),
        .m_ready       (m00_axis_tready),

        .done          (cfg_done)
    );

    // AXIS handshake
    assign s00_axis_tready  = cc_s_ready;

    assign m00_axis_tvalid  = cc_m_valid;
    assign m00_axis_tdata   = {24'd0, cc_m_data};   // pad upper 24 with 0
    assign m00_axis_tstrb   = 4'b0001;              // chỉ low byte valid
    assign m00_axis_tlast   = cfg_done && cc_m_valid;  // pulse last khi inference xong

    // IRQ
    assign irq = cfg_done;

    // -----------------------------------------------------------------------
    // (silence unused warnings for ports không dùng trong v2.0 alpha)
    // -----------------------------------------------------------------------
    // s00_axis_tstrb / s00_axis_tlast / s00_axis_aclk / s00_axis_aresetn
    // m00_axis_aclk / m00_axis_aresetn — assume cùng domain s00_axi_aclk
    /* verilator lint_off UNUSED */
    wire [(C_S00_AXIS_TDATA_WIDTH/8)-1:0] _u_strb = s00_axis_tstrb;
    wire _u_tlast = s00_axis_tlast;
    wire _u_acks  = s00_axis_aclk | m00_axis_aclk;
    wire _u_arsts = s00_axis_aresetn & m00_axis_aresetn;
    /* verilator lint_on UNUSED */

endmodule
