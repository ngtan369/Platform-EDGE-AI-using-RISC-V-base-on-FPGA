`timescale 1ns / 1ps

module riscv_top (
    input  logic clk_i,
    input  logic rst_ni,

    // ========================================================
    // AXI-Lite Master 0: Ðý?ng Instruction (Ch? Ð?c)
    // ========================================================
    output logic [31:0] m_axi_instr_araddr,
    output logic [2:0]  m_axi_instr_arprot,
    output logic        m_axi_instr_arvalid,
    input  logic        m_axi_instr_arready,
    input  logic [31:0] m_axi_instr_rdata,
    input  logic [1:0]  m_axi_instr_rresp,
    input  logic        m_axi_instr_rvalid,
    output logic        m_axi_instr_rready,

    // ========================================================
    // AXI-Lite Master 1: Ðý?ng Data (Ð?c & Ghi)
    // ========================================================
    output logic [31:0] m_axi_data_awaddr,
    output logic [2:0]  m_axi_data_awprot,
    output logic        m_axi_data_awvalid,
    input  logic        m_axi_data_awready,
    output logic [31:0] m_axi_data_wdata,
    output logic [3:0]  m_axi_data_wstrb,
    output logic        m_axi_data_wvalid,
    input  logic        m_axi_data_wready,
    input  logic [1:0]  m_axi_data_bresp,
    input  logic        m_axi_data_bvalid,
    output logic        m_axi_data_bready,

    output logic [31:0] m_axi_data_araddr,
    output logic [2:0]  m_axi_data_arprot,
    output logic        m_axi_data_arvalid,
    input  logic        m_axi_data_arready,
    input  logic [31:0] m_axi_data_rdata,
    input  logic [1:0]  m_axi_data_rresp,
    input  logic        m_axi_data_rvalid,
    output logic        m_axi_data_rready
);

    // --------------------------------------------------------
    // 1. T? ð?nh ngh?a Struct AXI n?i b? cho Vivado
    // --------------------------------------------------------
    typedef struct packed { logic [31:0] addr; logic [2:0] prot; } axi_aw_t;
    typedef struct packed { logic [31:0] data; logic [3:0] strb; } axi_w_t;
    typedef struct packed { logic [31:0] addr; logic [2:0] prot; } axi_ar_t;
    typedef struct packed { logic [1:0] resp; } axi_b_t;
    typedef struct packed { logic [31:0] data; logic [1:0] resp; } axi_r_t;

    typedef struct packed {
        axi_aw_t aw; logic aw_valid;
        axi_w_t  w;  logic w_valid;
        logic b_ready;
        axi_ar_t ar; logic ar_valid;
        logic r_ready;
    } axi_req_t;

    typedef struct packed {
        logic aw_ready; logic ar_ready; logic w_ready;
        logic b_valid; axi_b_t b;
        logic r_valid; axi_r_t r;
    } axi_rsp_t; 

    // --------------------------------------------------------
    // 2. Tuy?t chiêu "Duck Typing": T? t?o Struct OBI L?ng Nhau 
    // --------------------------------------------------------
    // Kh?i Req
    typedef struct packed { logic [2:0] prot; logic [5:0] atop; logic [1:0] memtype; } obi_req_opt_t;
    typedef struct packed { logic we; logic [3:0] be; logic [31:0] addr; logic [31:0] wdata; logic [3:0] aid; obi_req_opt_t a_optional; } obi_req_a_t;
    typedef struct packed { logic req; obi_req_a_t a; } custom_obi_req_t;

    // Kh?i Rsp
    typedef struct packed { logic exokay; logic ruser; } obi_rsp_opt_t;
    typedef struct packed { logic [31:0] rdata; logic err; logic [3:0] rid; obi_rsp_opt_t r_optional; } obi_rsp_r_t;
    typedef struct packed { logic gnt; logic rvalid; obi_rsp_r_t r; } custom_obi_resp_t;

    custom_obi_req_t  instr_req, data_req;
    custom_obi_resp_t instr_resp, data_resp;
    
    axi_req_t  instr_axi_req, data_axi_req;
    axi_rsp_t  instr_axi_rsp, data_axi_rsp;

    // Gán m?c ð?nh các chân không dùng 
    assign instr_req.a.we    = 1'b0;
    assign instr_req.a.be    = 4'b1111;
    assign instr_req.a.wdata = 32'b0;
    assign instr_req.a.aid   = '0;
    assign instr_req.a.a_optional = '0;
    
    assign data_req.a.aid         = '0;
    assign data_req.a.a_optional  = '0;

    // --------------------------------------------------------
    // 3. G?i l?i CPU CV32E40P
    // --------------------------------------------------------
    cv32e40p_top #(
        .FPU(0),          
        .COREV_PULP(0)    
    ) u_core (
        .clk_i           (clk_i),
        .rst_ni          (rst_ni),
        .pulp_clock_en_i (1'b1),
        .scan_cg_en_i    (1'b0),
        .boot_addr_i     (32'h00000000), 
        .irq_i           (32'b0),
        .irq_ack_o       (),
        .irq_id_o        (),
        .debug_req_i     (1'b0),
        .debug_havereset_o(),
        .debug_running_o (),
        .debug_halted_o  (),
        .fetch_enable_i  (1'b1),
        .core_sleep_o    (),

        // OBI Instruction 
        .instr_req_o     (instr_req.req),
        .instr_gnt_i     (instr_resp.gnt),
        .instr_rvalid_i  (instr_resp.rvalid),
        .instr_addr_o    (instr_req.a.addr),
        .instr_rdata_i   (instr_resp.r.rdata), // N?i ðúng vào t?ng .r.rdata

        // OBI Data
        .data_req_o      (data_req.req),
        .data_gnt_i      (data_resp.gnt),
        .data_rvalid_i   (data_resp.rvalid),
        .data_we_o       (data_req.a.we),
        .data_be_o       (data_req.a.be),
        .data_addr_o     (data_req.a.addr),
        .data_wdata_o    (data_req.a.wdata),
        .data_rdata_i    (data_resp.r.rdata)   // N?i ðúng vào t?ng .r.rdata
    );

    // --------------------------------------------------------
    // 4. Kh?i Bridge OBI sang AXI cho L?nh (Instruction)
    // --------------------------------------------------------
    obi_to_axi #(
        .AxiLite   (1'b1),
        .obi_req_t (custom_obi_req_t),
        .obi_rsp_t (custom_obi_resp_t),
        .axi_req_t (axi_req_t),
        .axi_rsp_t (axi_rsp_t)
    ) bridge_instr (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .obi_req_i(instr_req), .obi_rsp_o(instr_resp),
        .axi_req_o(instr_axi_req), .axi_rsp_i(instr_axi_rsp),
        .user_i('0), .obi_rsp_user_i('0), .axi_rsp_channel_sel(), .axi_rsp_b_user_o(), .axi_rsp_r_user_o()
    );

    assign m_axi_instr_araddr  = instr_axi_req.ar.addr;
    assign m_axi_instr_arprot  = instr_axi_req.ar.prot;
    assign m_axi_instr_arvalid = instr_axi_req.ar_valid;
    assign instr_axi_rsp.ar_ready = m_axi_instr_arready;
    
    assign instr_axi_rsp.r.data   = m_axi_instr_rdata;
    assign instr_axi_rsp.r.resp   = m_axi_instr_rresp;
    assign instr_axi_rsp.r_valid  = m_axi_instr_rvalid;
    assign m_axi_instr_rready  = instr_axi_req.r_ready;

    // --------------------------------------------------------
    // 5. Kh?i Bridge OBI sang AXI cho D? li?u (Data)
    // --------------------------------------------------------
    obi_to_axi #(
        .AxiLite   (1'b1),
        .obi_req_t (custom_obi_req_t),
        .obi_rsp_t (custom_obi_resp_t),
        .axi_req_t (axi_req_t),
        .axi_rsp_t (axi_rsp_t)
    ) bridge_data (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .obi_req_i(data_req), .obi_rsp_o(data_resp),
        .axi_req_o(data_axi_req), .axi_rsp_i(data_axi_rsp),
        .user_i('0), .obi_rsp_user_i('0), .axi_rsp_channel_sel(), .axi_rsp_b_user_o(), .axi_rsp_r_user_o()
    );

    assign m_axi_data_awaddr  = data_axi_req.aw.addr;
    assign m_axi_data_awprot  = data_axi_req.aw.prot;
    assign m_axi_data_awvalid = data_axi_req.aw_valid;
    assign data_axi_rsp.aw_ready = m_axi_data_awready;

    assign m_axi_data_wdata   = data_axi_req.w.data;
    assign m_axi_data_wstrb   = data_axi_req.w.strb;
    assign m_axi_data_wvalid  = data_axi_req.w_valid;
    assign data_axi_rsp.w_ready  = m_axi_data_wready;

    assign data_axi_rsp.b.resp   = m_axi_data_bresp;
    assign data_axi_rsp.b_valid  = m_axi_data_bvalid;
    assign m_axi_data_bready  = data_axi_req.b_ready;

    assign m_axi_data_araddr  = data_axi_req.ar.addr;
    assign m_axi_data_arprot  = data_axi_req.ar.prot;
    assign m_axi_data_arvalid = data_axi_req.ar_valid;
    assign data_axi_rsp.ar_ready = m_axi_data_arready;

    assign data_axi_rsp.r.data   = m_axi_data_rdata;
    assign data_axi_rsp.r.resp   = m_axi_data_rresp;
    assign data_axi_rsp.r_valid  = m_axi_data_rvalid;
    assign m_axi_data_rready  = data_axi_req.r_ready;

endmodule