// =============================================================================
// tb_riscv_top.sv — Smoke testbench cho RISC-V wrapper.
//
// Mục tiêu: validate mux 2 OBI→AXI bridge + CV32E40P khởi động và phát fetch
// request hợp lệ. Không kiểm tra functional correctness của program (cần
// memory model thật cho việc đó).
//
// Test case:
//   1. Reset 5 cycles, deassert.
//   2. Set fetch_enable_i = 1.
//   3. Drive instr_arready = 1, response NOP (0x00000013) cho mọi fetch.
//   4. Drive data_*ready = 0 (RISC-V không truy cập data trong NOP-loop).
//   5. Run 100 cycles, kiểm tra fetch addresses tăng đều (4 byte mỗi lần).
//
// Pass criteria:
//   - axi_instr_arvalid pulses ít nhất 5 lần
//   - Subsequent araddr values tăng monotonically (PC advance)
// =============================================================================
`timescale 1ns/1ps

module tb_riscv_top;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk_i = 0;
    logic        rst_ni;
    logic        fetch_enable_i;
    logic        irq_conv_cnn_i;
    logic        core_sleep_o;

    // Instr AXI-Lite
    logic [31:0] m_axi_instr_araddr;
    logic [2:0]  m_axi_instr_arprot;
    logic        m_axi_instr_arvalid;
    logic        m_axi_instr_arready;
    logic [31:0] m_axi_instr_rdata;
    logic [1:0]  m_axi_instr_rresp;
    logic        m_axi_instr_rvalid;
    logic        m_axi_instr_rready;

    // Data AXI-Lite (unused in NOP-loop, tied off)
    logic [31:0] m_axi_data_awaddr;
    logic [2:0]  m_axi_data_awprot;
    logic        m_axi_data_awvalid;
    logic        m_axi_data_awready;
    logic [31:0] m_axi_data_wdata;
    logic [3:0]  m_axi_data_wstrb;
    logic        m_axi_data_wvalid;
    logic        m_axi_data_wready;
    logic [1:0]  m_axi_data_bresp;
    logic        m_axi_data_bvalid;
    logic        m_axi_data_bready;
    logic [31:0] m_axi_data_araddr;
    logic [2:0]  m_axi_data_arprot;
    logic        m_axi_data_arvalid;
    logic        m_axi_data_arready;
    logic [31:0] m_axi_data_rdata;
    logic [1:0]  m_axi_data_rresp;
    logic        m_axi_data_rvalid;
    logic        m_axi_data_rready;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    riscv_top dut (.*);

    // -------------------------------------------------------------------------
    // Clock 100 MHz
    // -------------------------------------------------------------------------
    always #5 clk_i = ~clk_i;

    // -------------------------------------------------------------------------
    // Behavioral instr memory: respond every fetch with NOP (addi x0, x0, 0)
    // -------------------------------------------------------------------------
    localparam logic [31:0] NOP_INSTR = 32'h00000013;

    // AR handshake — always ready (1-cycle latency to R)
    assign m_axi_instr_arready = 1'b1;

    // R channel pipeline: 1-cycle delay after AR handshake
    logic ar_handshake;
    assign ar_handshake = m_axi_instr_arvalid && m_axi_instr_arready;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m_axi_instr_rvalid <= 1'b0;
            m_axi_instr_rdata  <= 32'b0;
            m_axi_instr_rresp  <= 2'b0;
        end else begin
            // Pulse rvalid 1 cycle after AR handshake
            if (ar_handshake) begin
                m_axi_instr_rvalid <= 1'b1;
                m_axi_instr_rdata  <= NOP_INSTR;
                m_axi_instr_rresp  <= 2'b00;       // OKAY
            end else if (m_axi_instr_rvalid && m_axi_instr_rready) begin
                m_axi_instr_rvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Tie off data AXI ports — RISC-V không issue load/store cho NOP
    // -------------------------------------------------------------------------
    assign m_axi_data_awready = 1'b0;
    assign m_axi_data_wready  = 1'b0;
    assign m_axi_data_bvalid  = 1'b0;
    assign m_axi_data_bresp   = 2'b0;
    assign m_axi_data_arready = 1'b0;
    assign m_axi_data_rvalid  = 1'b0;
    assign m_axi_data_rdata   = 32'b0;
    assign m_axi_data_rresp   = 2'b0;

    // -------------------------------------------------------------------------
    // Track fetch progress
    // -------------------------------------------------------------------------
    int          fetch_count;
    logic [31:0] last_addr;
    int          n_errors;
    bit          first_fetch;

    initial begin
        fetch_count = 0;
        last_addr   = 32'hFFFF_FFFF;
        n_errors    = 0;
        first_fetch = 1;
    end

    always_ff @(posedge clk_i) begin
        if (rst_ni && ar_handshake) begin
            fetch_count <= fetch_count + 1;
            if (!first_fetch) begin
                if (m_axi_instr_araddr <= last_addr) begin
                    $display("[%0t] FAIL fetch addr 0x%08X did not advance from 0x%08X",
                             $time, m_axi_instr_araddr, last_addr);
                    n_errors <= n_errors + 1;
                end
            end
            last_addr   <= m_axi_instr_araddr;
            first_fetch <= 0;
            $display("[%0t] FETCH #%0d addr=0x%08X", $time, fetch_count, m_axi_instr_araddr);
        end
    end

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        rst_ni         = 0;
        fetch_enable_i = 0;
        irq_conv_cnn_i = 0;

        repeat (5) @(posedge clk_i);
        rst_ni = 1;

        repeat (3) @(posedge clk_i);
        fetch_enable_i = 1;     // CV32E40P starts fetching

        // Run 100 cycles
        repeat (100) @(posedge clk_i);

        // Pulse IRQ then deassert
        irq_conv_cnn_i = 1;
        @(posedge clk_i);
        irq_conv_cnn_i = 0;

        repeat (50) @(posedge clk_i);

        // -------------------------------------------------------------------
        // Pass criteria
        // -------------------------------------------------------------------
        $display("\n=========================================");
        $display(" Total fetches: %0d", fetch_count);
        $display(" Errors:        %0d", n_errors);
        $display("=========================================");

        if (fetch_count >= 5 && n_errors == 0)
            $display("[%0t] ✓✓✓ TEST PASSED — fetch addresses advance correctly", $time);
        else
            $display("[%0t] ✗ TEST FAILED — fetch_count=%0d errors=%0d",
                     $time, fetch_count, n_errors);

        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #50_000;
        $display("[%0t] WATCHDOG TIMEOUT", $time);
        $finish;
    end

endmodule
