
`timescale 1 ns / 1 ps

	module conv_cnn_v1_0 #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 4,

		// Parameters of Axi Slave Bus Interface S00_AXIS
		parameter integer C_S00_AXIS_TDATA_WIDTH	= 32,

		// Parameters of Axi Master Bus Interface M00_AXIS
		parameter integer C_M00_AXIS_TDATA_WIDTH	= 32,
		parameter integer C_M00_AXIS_START_COUNT	= 32
	)
	(
		// Users to add ports here

        //  Dành cho CV32E40P hoặc ARM
        output wire irq,

		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S00_AXI
		input wire  s00_axi_aclk,
		input wire  s00_axi_aresetn,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
		input wire [2 : 0] s00_axi_awprot,
		input wire  s00_axi_awvalid,
		output wire  s00_axi_awready,
		input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
		input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
		input wire  s00_axi_wvalid,
		output wire  s00_axi_wready,
		output wire [1 : 0] s00_axi_bresp,
		output wire  s00_axi_bvalid,
		input wire  s00_axi_bready,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
		input wire [2 : 0] s00_axi_arprot,
		input wire  s00_axi_arvalid,
		output wire  s00_axi_arready,
		output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
		output wire [1 : 0] s00_axi_rresp,
		output wire  s00_axi_rvalid,
		input wire  s00_axi_rready,

		// Ports of Axi Slave Bus Interface S00_AXIS
		input wire  s00_axis_aclk,
		input wire  s00_axis_aresetn,
		output wire  s00_axis_tready,
		input wire [C_S00_AXIS_TDATA_WIDTH-1 : 0] s00_axis_tdata,
		input wire [(C_S00_AXIS_TDATA_WIDTH/8)-1 : 0] s00_axis_tstrb,
		input wire  s00_axis_tlast,
		input wire  s00_axis_tvalid,

		// Ports of Axi Master Bus Interface M00_AXIS
		input wire  m00_axis_aclk,
		input wire  m00_axis_aresetn,
		output wire  m00_axis_tvalid,
		output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0] m00_axis_tdata,
		output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
		output wire  m00_axis_tlast,
		input wire  m00_axis_tready
	);
    // Instantiation of Axi Bus Interface S00_AXI   
    // Custom
    wire [31:0] w_active_width;
    wire        w_start;
    wire        w_done;
    wire w_pool_en;
    // endCustom
	conv_cnn_v1_0_S00_AXI # ( 
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
	) conv_cnn_v1_0_S00_AXI_inst (
		.S_AXI_ACLK(s00_axi_aclk),
		.S_AXI_ARESETN(s00_axi_aresetn),
		.S_AXI_AWADDR(s00_axi_awaddr),
		.S_AXI_AWPROT(s00_axi_awprot),
		.S_AXI_AWVALID(s00_axi_awvalid),
		.S_AXI_AWREADY(s00_axi_awready),
		.S_AXI_WDATA(s00_axi_wdata),
		.S_AXI_WSTRB(s00_axi_wstrb),
		.S_AXI_WVALID(s00_axi_wvalid),
		.S_AXI_WREADY(s00_axi_wready),
		.S_AXI_BRESP(s00_axi_bresp),
		.S_AXI_BVALID(s00_axi_bvalid),
		.S_AXI_BREADY(s00_axi_bready),
		.S_AXI_ARADDR(s00_axi_araddr),
		.S_AXI_ARPROT(s00_axi_arprot),
		.S_AXI_ARVALID(s00_axi_arvalid),
		.S_AXI_ARREADY(s00_axi_arready),
		.S_AXI_RDATA(s00_axi_rdata),
		.S_AXI_RRESP(s00_axi_rresp),
		.S_AXI_RVALID(s00_axi_rvalid),
		.S_AXI_RREADY(s00_axi_rready),

        // Custom
        .out_active_width(w_active_width),
        .out_start       (w_start),
        .in_done         (w_done),
        .out_pool_en (w_pool_en)
	);

// Instantiation of Axi Bus Interface S00_AXIS
	// conv_cnn_v1_0_S00_AXIS # ( 
	// 	.C_S_AXIS_TDATA_WIDTH(C_S00_AXIS_TDATA_WIDTH)
	// ) conv_cnn_v1_0_S00_AXIS_inst (
	// 	.S_AXIS_ACLK(s00_axis_aclk),
	// 	.S_AXIS_ARESETN(s00_axis_aresetn),
	// 	.S_AXIS_TREADY(s00_axis_tready),
	// 	.S_AXIS_TDATA(s00_axis_tdata),
	// 	.S_AXIS_TSTRB(s00_axis_tstrb),
	// 	.S_AXIS_TLAST(s00_axis_tlast),
	// 	.S_AXIS_TVALID(s00_axis_tvalid)
	// );

// Instantiation of Axi Bus Interface M00_AXIS
	// conv_cnn_v1_0_M00_AXIS # ( 
	// 	.C_M_AXIS_TDATA_WIDTH(C_M00_AXIS_TDATA_WIDTH),
	// 	.C_M_START_COUNT(C_M00_AXIS_START_COUNT)
    // ) conv_cnn_v1_0_M00_AXIS_inst (
	// 	.M_AXIS_ACLK(m00_axis_aclk),
	// 	.M_AXIS_ARESETN(m00_axis_aresetn),
	// 	.M_AXIS_TVALID(m00_axis_tvalid),
	// 	.M_AXIS_TDATA(m00_axis_tdata),
	// 	.M_AXIS_TSTRB(m00_axis_tstrb),
	// 	.M_AXIS_TLAST(m00_axis_tlast),
	// 	.M_AXIS_TREADY(m00_axis_tready)
	// );

	// Add user logic here
    //Tìm một thanh ghi còn trống (ví dụ slv_reg0). �?ịnh nghĩa nó là thanh ghi chứa độ rộng ảnh (Image Width).
    conv_core u_conv (
        .clk          (s00_axi_aclk),
        .rst_n        (s00_axi_aresetn),

        // �?i�?u khiển từ AXI-Lite
        .start        (w_start),
        .active_width (w_active_width[9:0]), // Ép kiểu 32-bit xuống 10-bit
        .num_cin      (10'd3),               // Ví dụ cố định, hoặc kéo từ slv_reg ra
        
        // Giao tiếp với AXIS IN (Nhận ảnh)
        .s_data       (s00_axis_tdata[7:0]), // Lấy 8 bit data
        .s_valid      (s00_axis_tvalid),
        .s_ready      (s00_axis_tready),

        // Giao tiếp với AXIS OUT (Trả kết quả)
        .m_data       (m00_axis_tdata[7:0]),
        .m_valid      (m00_axis_tvalid),
        .m_ready      (m00_axis_tready),
        
        // --- B? SUNG 9 C?M D�Y TR?NG S? (B? L?C BI�N SOBEL) ---
        .w00 (8'sd1),  .w01 (8'sd0), .w02 (-8'sd1),
        .w10 (8'sd2),  .w11 (8'sd0), .w12 (-8'sd2),
        .w20 (8'sd1),  .w21 (8'sd0), .w22 (-8'sd1),
        
        .done         (w_done),
        .pool_en (w_pool_en)
    );
    // Gắn các chân Stream còn dư để không bị báo lỗi (Padding)
    assign m00_axis_tdata[31:8] = 24'd0;
    assign m00_axis_tstrb = 4'b1111;
    assign m00_axis_tlast = w_done; // Bật c�? Last khi xong 1 frame

    // Tín hiệu ngắt báo cho CPU
    assign irq = w_done;
    
	// User logic ends

	endmodule
    // output wire interrupt
    // Nối dây ngắt này vào bộ đi�?u khiển ngắt (PLIC hoặc lõi ngắt nội bộ) của CV32E40P. 
    // Hệ thống của bạn sẽ mang dáng dấp của một SoC công nghiệp thực thụ.