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
    // 32→8 INPUT BYTE UNPACKER
    //   DMA streams 32-bit beats; conv_core consumes 1 byte per s_valid pulse.
    //   Per beat: distribute 4 bytes (low→high) over 4 conv_core handshake cycles.
    //   Backpressure to DMA: s00_axis_tready=1 only when current beat is empty.
    // -----------------------------------------------------------------------
    reg  [31:0] beat_data;
    reg  [1:0]  byte_idx;
    reg         beat_valid;

    wire        cc_s_ready;
    wire        core_s_valid = beat_valid;
    wire [7:0]  core_s_data  = beat_data[byte_idx*8 +: 8];
    wire        core_consume = beat_valid & cc_s_ready;   // conv_core takes byte
    wire        accept_beat  = s00_axis_tvalid & ~beat_valid;

    always @(posedge s00_axi_aclk or negedge s00_axi_aresetn) begin
        if (!s00_axi_aresetn) begin
            beat_data  <= 32'd0;
            byte_idx   <= 2'd0;
            beat_valid <= 1'b0;
        end else if (accept_beat) begin
            beat_data  <= s00_axis_tdata;
            byte_idx   <= 2'd0;
            beat_valid <= 1'b1;
        end else if (core_consume) begin
            if (byte_idx == 2'd3) begin
                beat_valid <= 1'b0;
            end else begin
                byte_idx <= byte_idx + 2'd1;
            end
        end
    end

    assign s00_axis_tready = ~beat_valid;   // accept next beat when current drained

    // -----------------------------------------------------------------------
    // 8→32 OUTPUT BYTE PACKER
    //   conv_core emits 1 byte per m_valid; pack 4 bytes into 1 AXIS beat.
    //   Emit beat when: (a) 4 bytes collected, OR (b) inference done (flush partial).
    // -----------------------------------------------------------------------
    wire        cc_m_valid;
    wire [7:0]  cc_m_data;

    reg  [31:0] pack_data;
    reg  [1:0]  pack_idx;
    reg         pack_emit;          // 1 = drive m00_axis_tvalid

    wire        core_produce = cc_m_valid & ~pack_emit;  // accept conv_core byte
    wire        beat_sent    = pack_emit & m00_axis_tready;

    always @(posedge s00_axi_aclk or negedge s00_axi_aresetn) begin
        if (!s00_axi_aresetn) begin
            pack_data <= 32'd0;
            pack_idx  <= 2'd0;
            pack_emit <= 1'b0;
        end else if (beat_sent) begin
            // Beat consumed: clear emit, reset pack_idx for next group
            pack_emit <= 1'b0;
            pack_idx  <= 2'd0;
            pack_data <= 32'd0;
        end else if (core_produce) begin
            pack_data[pack_idx*8 +: 8] <= cc_m_data;
            if (pack_idx == 2'd3) begin
                pack_emit <= 1'b1;       // beat full → emit next cycle
                pack_idx  <= 2'd0;
            end else begin
                pack_idx <= pack_idx + 2'd1;
            end
        end
    end

    // m_ready to conv_core: accept new byte unless we're holding a full beat
    wire core_m_ready_internal = ~pack_emit;

    // -----------------------------------------------------------------------
    // conv_core (v2.0 SV datapath top)
    // -----------------------------------------------------------------------
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

        // 8-bit AXIS in (from unpacker)
        .s_data        (core_s_data),
        .s_valid       (core_s_valid),
        .s_ready       (cc_s_ready),

        // 8-bit AXIS out (to packer)
        .m_data        (cc_m_data),
        .m_valid       (cc_m_valid),
        .m_ready       (core_m_ready_internal),

        .done          (cfg_done)
    );

    // M00_AXIS output (packed 32-bit beats)
    assign m00_axis_tvalid  = pack_emit;
    assign m00_axis_tdata   = pack_data;
    assign m00_axis_tstrb   = 4'b1111;
    assign m00_axis_tlast   = cfg_done && pack_emit;

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
