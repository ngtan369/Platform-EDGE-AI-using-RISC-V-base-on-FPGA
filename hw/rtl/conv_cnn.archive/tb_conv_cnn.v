`timescale 1ns / 1ps

module tb_conv_cnn();

    // 1. Khai báo tín hiệu giả lập
    reg clk;
    reg reset_n;
    
    // Khai báo các tín hiệu AXI-Lite (Master đóng giả)
    reg [31:0] s_axi_awaddr;
    reg        s_axi_awvalid;
    wire       s_axi_awready; // CNN trả về
    reg [31:0] s_axi_wdata;
    reg        s_axi_wvalid;
    wire       s_axi_wready;  // CNN trả về
    
    // Khởi tạo khối CNN (DUT - Design Under Test)
    conv_cnn_v1_0 DUT (
        .s00_axi_aclk(clk),
        .s00_axi_aresetn(reset_n),
        .s00_axi_awaddr(s_axi_awaddr),
        .s00_axi_awvalid(s_axi_awvalid),
        .s00_axi_awready(s_axi_awready),
        .s00_axi_wdata(s_axi_wdata),
        .s00_axi_wvalid(s_axi_wvalid),
        .s00_axi_wready(s_axi_wready)
        // ... (Khai báo thêm các cổng b/ar/r nếu cần) ...
    );

    // 2. Tạo Xung nhịp (Clock 100MHz)
    always #5 clk = ~clk;

    // 3. Kịch bản Test (Tương đương code C: Xil_Out32)
    initial begin
        // Khởi tạo trạng thái ban đầu
        clk = 0;
        reset_n = 0;
        s_axi_awvalid = 0;
        s_axi_wvalid = 0;
        
        // Bấm nút Reset
        #20 reset_n = 1;
        #20;
        
        $display("--- BAT DAU GIA LAP GUI LENH START ---");
        
        // Bước 1: Gửi Địa chỉ (Giả sử thanh ghi Start ở Offset 0x00)
        s_axi_awaddr = 32'h00000000; 
        s_axi_awvalid = 1;
        // Chờ CNN báo Ready
        wait (s_axi_awready == 1'b1);
        @(posedge clk);
        s_axi_awvalid = 0; // Gửi xong hạ xuống
        
        // Bước 2: Gửi Dữ liệu (Ghi số 1 để Start)
        s_axi_wdata = 32'h00000001;
        s_axi_wvalid = 1;
        // Chờ CNN báo Ready
        wait (s_axi_wready == 1'b1);
        @(posedge clk);
        s_axi_wvalid = 0; // Gửi xong hạ xuống
        
        $display("--- DA GUI LENH START THANH CONG ---");
        
        // Đợi 1000 clock để xem CNN tính toán ra sao trên Waveform
        #10000;
        $finish;
    end

endmodule