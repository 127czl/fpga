`timescale 1ns/1ps

// Delay original RGB by the same three 3x3 stages used by
// RGB -> gray -> median -> Gaussian -> Sobel.
//
// The data only passes through p22 of each stage; the point is to reproduce
// the same line and pixel latency so the delayed colour image can be mixed
// with the Sobel edge output without a separate DDR read port.
module VIP_RGB888_DelaySobel #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080
    )(
    input               clk,
    input               rst_n,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_red,
    input       [7:0]   per_img_green,
    input       [7:0]   per_img_blue,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue
    );

    // Match the RGB888_Gray module's one output register before the three
    // spatial stages below.
    reg [7:0] in_r, in_g, in_b;
    reg       in_v, in_h, in_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_r <= 8'd0; in_g <= 8'd0; in_b <= 8'd0;
            in_v <= 1'b0; in_h <= 1'b0; in_s <= 1'b0;
        end else begin
            in_r <= per_img_red;
            in_g <= per_img_green;
            in_b <= per_img_blue;
            in_v <= per_frame_vsync;
            in_h <= per_frame_href;
            in_s <= per_frame_hsync;
        end
    end

    // ---------------- stage 1: median-filter latency ----------------
    wire        m1_vsync, m1_href, m1_hsync;
    wire [7:0]  s1_r11, s1_r12, s1_r13, s1_r21, s1_r22, s1_r23, s1_r31, s1_r32, s1_r33;
    wire [7:0]  s1_g22, s1_b22;

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s1_r (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(in_v), .per_frame_href(in_h),
        .per_frame_hsync(in_s), .per_img_Y(in_r),
        .matrix_frame_vsync(m1_vsync), .matrix_frame_href(m1_href),
        .matrix_frame_hsync(m1_hsync),
        .matrix_p11(s1_r11), .matrix_p12(s1_r12), .matrix_p13(s1_r13),
        .matrix_p21(s1_r21), .matrix_p22(s1_r22), .matrix_p23(s1_r23),
        .matrix_p31(s1_r31), .matrix_p32(s1_r32), .matrix_p33(s1_r33)
    );

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s1_g (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(in_v), .per_frame_href(in_h),
        .per_frame_hsync(in_s), .per_img_Y(in_g),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_hsync(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s1_g22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s1_b (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(in_v), .per_frame_href(in_h),
        .per_frame_hsync(in_s), .per_img_Y(in_b),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_hsync(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s1_b22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    reg [7:0] s1_r_a, s1_r_b, s1_r_c;
    reg [7:0] s1_g_a, s1_g_b, s1_g_c;
    reg [7:0] s1_b_a, s1_b_b, s1_b_c;
    reg       s1_v_a, s1_v_b, s1_v_c;
    reg       s1_h_a, s1_h_b, s1_h_c;
    reg       s1_s_a, s1_s_b, s1_s_c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_r_a <= 0; s1_r_b <= 0; s1_r_c <= 0;
            s1_g_a <= 0; s1_g_b <= 0; s1_g_c <= 0;
            s1_b_a <= 0; s1_b_b <= 0; s1_b_c <= 0;
            s1_v_a <= 0; s1_v_b <= 0; s1_v_c <= 0;
            s1_h_a <= 0; s1_h_b <= 0; s1_h_c <= 0;
            s1_s_a <= 0; s1_s_b <= 0; s1_s_c <= 0;
        end else begin
            s1_r_a <= s1_r22; s1_r_b <= s1_r_a; s1_r_c <= s1_r_b;
            s1_g_a <= s1_g22; s1_g_b <= s1_g_a; s1_g_c <= s1_g_b;
            s1_b_a <= s1_b22; s1_b_b <= s1_b_a; s1_b_c <= s1_b_b;
            s1_v_a <= m1_vsync; s1_v_b <= s1_v_a; s1_v_c <= s1_v_b;
            s1_h_a <= m1_href;  s1_h_b <= s1_h_a; s1_h_c <= s1_h_b;
            s1_s_a <= m1_hsync; s1_s_b <= s1_s_a; s1_s_c <= s1_s_b;
        end
    end

    // ---------------- stage 2: Gaussian latency ----------------
    wire        m2_vsync, m2_href, m2_hsync;
    wire [7:0]  s2_r22, s2_g22, s2_b22;

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s2_r (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(s1_v_c), .per_frame_href(s1_h_c), .per_frame_hsync(s1_s_c),
        .per_img_Y(s1_r_c),
        .matrix_frame_vsync(m2_vsync), .matrix_frame_href(m2_href), .matrix_frame_hsync(m2_hsync),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s2_r22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s2_g (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(s1_v_c), .per_frame_href(s1_h_c), .per_frame_hsync(s1_s_c),
        .per_img_Y(s1_g_c),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_hsync(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s2_g22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s2_b (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(s1_v_c), .per_frame_href(s1_h_c), .per_frame_hsync(s1_s_c),
        .per_img_Y(s1_b_c),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_hsync(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s2_b22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    reg [7:0] s2_r_a, s2_r_b;
    reg [7:0] s2_g_a, s2_g_b;
    reg [7:0] s2_b_a, s2_b_b;
    reg       s2_v_a, s2_v_b;
    reg       s2_h_a, s2_h_b;
    reg       s2_s_a, s2_s_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_r_a <= 0; s2_r_b <= 0; s2_g_a <= 0; s2_g_b <= 0; s2_b_a <= 0; s2_b_b <= 0;
            s2_v_a <= 0; s2_v_b <= 0; s2_h_a <= 0; s2_h_b <= 0; s2_s_a <= 0; s2_s_b <= 0;
        end else begin
            s2_r_a <= s2_r22; s2_r_b <= s2_r_a;
            s2_g_a <= s2_g22; s2_g_b <= s2_g_a;
            s2_b_a <= s2_b22; s2_b_b <= s2_b_a;
            s2_v_a <= m2_vsync; s2_v_b <= s2_v_a;
            s2_h_a <= m2_href;  s2_h_b <= s2_h_a;
            s2_s_a <= m2_hsync; s2_s_b <= s2_s_a;
        end
    end

    // ---------------- stage 3: Sobel latency ----------------
    wire        m3_vsync, m3_href, m3_hsync;
    wire [7:0]  s3_r22, s3_g22, s3_b22;

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s3_r (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(s2_v_b), .per_frame_href(s2_h_b), .per_frame_hsync(s2_s_b),
        .per_img_Y(s2_r_b),
        .matrix_frame_vsync(m3_vsync), .matrix_frame_href(m3_href), .matrix_frame_hsync(m3_hsync),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s3_r22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s3_g (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(s2_v_b), .per_frame_href(s2_h_b), .per_frame_hsync(s2_s_b),
        .per_img_Y(s2_g_b),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_hsync(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s3_g22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    VIP_Matrix_Generate_3X3_8Bit #(.IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP))
    u_s3_b (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(s2_v_b), .per_frame_href(s2_h_b), .per_frame_hsync(s2_s_b),
        .per_img_Y(s2_b_b),
        .matrix_frame_vsync(), .matrix_frame_href(), .matrix_frame_hsync(),
        .matrix_p11(), .matrix_p12(), .matrix_p13(),
        .matrix_p21(), .matrix_p22(s3_b22), .matrix_p23(),
        .matrix_p31(), .matrix_p32(), .matrix_p33()
    );

    // Sobel adds two output pipeline stages after its 3x3 matrix; match both.
    reg [7:0] s3_r_a, s3_r_b;
    reg [7:0] s3_g_a, s3_g_b;
    reg [7:0] s3_b_a, s3_b_b;
    reg       s3_v_a, s3_v_b;
    reg       s3_h_a, s3_h_b;
    reg       s3_s_a, s3_s_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_r_a <= 0; s3_r_b <= 0; s3_g_a <= 0; s3_g_b <= 0; s3_b_a <= 0; s3_b_b <= 0;
            s3_v_a <= 0; s3_v_b <= 0; s3_h_a <= 0; s3_h_b <= 0; s3_s_a <= 0; s3_s_b <= 0;
            post_img_red <= 8'd0;
            post_img_green <= 8'd0;
            post_img_blue <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            s3_r_a <= s3_r22; s3_r_b <= s3_r_a;
            s3_g_a <= s3_g22; s3_g_b <= s3_g_a;
            s3_b_a <= s3_b22; s3_b_b <= s3_b_a;
            s3_v_a <= m3_vsync; s3_v_b <= s3_v_a;
            s3_h_a <= m3_href;  s3_h_b <= s3_h_a;
            s3_s_a <= m3_hsync; s3_s_b <= s3_s_a;

            post_img_red     <= s3_r_b;
            post_img_green   <= s3_g_b;
            post_img_blue    <= s3_b_b;
            post_frame_vsync <= s3_v_b;
            post_frame_href  <= s3_h_b;
            post_frame_hsync <= s3_s_b;
        end
    end

endmodule
