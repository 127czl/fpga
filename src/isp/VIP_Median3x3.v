`timescale 1ns/1ps

// 3x3 median filter for the 8-bit grey path.
//
// Exact median of 9 with the classic network: sort each row, then take the
// median of the three row maxima, of the three row medians and of the three
// row minima, and finally the median of those three. 21 compare-exchange
// units in total, fully parallel, no sorting loop.
//
//   stage 1 : sort each row            (3 compare-exchanges per row)
//   stage 2 : median of the hi/mid/lo  (three med3 blocks)
//   stage 3 : median of those three    (one med3 block)
//
// The 3x3 window needs two line buffers, the same structure the Sobel uses.
module VIP_Median3x3 #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080
    )(
    input               clk,
    input               rst_n,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_gray,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_gray
    );

    wire            matrix_vsync, matrix_href, matrix_hsync;
    wire [7:0]      p11, p12, p13;
    wire [7:0]      p21, p22, p23;
    wire [7:0]      p31, p32, p33;

    VIP_Matrix_Generate_3X3_8Bit #(
        .IMG_HDISP  (IMG_HDISP),
        .IMG_VDISP  (IMG_VDISP)
    ) u_matrix_3x3 (
        .clk                (clk),
        .rst_n              (rst_n),
        .per_frame_vsync    (per_frame_vsync),
        .per_frame_href     (per_frame_href),
        .per_frame_hsync    (per_frame_hsync),
        .per_img_Y          (per_img_gray),
        .matrix_frame_vsync (matrix_vsync),
        .matrix_frame_href  (matrix_href),
        .matrix_frame_hsync (matrix_hsync),
        .matrix_p11         (p11),
        .matrix_p12         (p12),
        .matrix_p13         (p13),
        .matrix_p21         (p21),
        .matrix_p22         (p22),
        .matrix_p23         (p23),
        .matrix_p31         (p31),
        .matrix_p32         (p32),
        .matrix_p33         (p33)
    );

    function [7:0] max8;
        input [7:0] a;
        input [7:0] b;
        begin
            max8 = (a > b) ? a : b;
        end
    endfunction

    function [7:0] min8;
        input [7:0] a;
        input [7:0] b;
        begin
            min8 = (a < b) ? a : b;
        end
    endfunction

    // median of three = clamp the third value into [min(a,b), max(a,b)]
    function [7:0] med3;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        reg   [7:0] lo;
        reg   [7:0] hi;
        begin
            lo = min8(a, b);
            hi = max8(a, b);
            med3 = (c < lo) ? lo : ((c > hi) ? hi : c);
        end
    endfunction

    // ---- stage 1: ascending sort of each row (3 compare-exchanges) ----
    // row 0
    wire [7:0] r0_a1 = max8(p11, p12);
    wire [7:0] r0_b1 = min8(p11, p12);
    wire [7:0] r0_b2 = max8(r0_b1, p13);
    wire [7:0] r0_c2 = min8(r0_b1, p13);
    wire [7:0] r0_hi = max8(r0_a1, r0_b2);
    wire [7:0] r0_md = min8(r0_a1, r0_b2);
    wire [7:0] r0_lo = r0_c2;

    // row 1
    wire [7:0] r1_a1 = max8(p21, p22);
    wire [7:0] r1_b1 = min8(p21, p22);
    wire [7:0] r1_b2 = max8(r1_b1, p23);
    wire [7:0] r1_c2 = min8(r1_b1, p23);
    wire [7:0] r1_hi = max8(r1_a1, r1_b2);
    wire [7:0] r1_md = min8(r1_a1, r1_b2);
    wire [7:0] r1_lo = r1_c2;

    // row 2
    wire [7:0] r2_a1 = max8(p31, p32);
    wire [7:0] r2_b1 = min8(p31, p32);
    wire [7:0] r2_b2 = max8(r2_b1, p33);
    wire [7:0] r2_c2 = min8(r2_b1, p33);
    wire [7:0] r2_hi = max8(r2_a1, r2_b2);
    wire [7:0] r2_md = min8(r2_a1, r2_b2);
    wire [7:0] r2_lo = r2_c2;

    reg [7:0] s1_hi0, s1_hi1, s1_hi2;
    reg [7:0] s1_md0, s1_md1, s1_md2;
    reg [7:0] s1_lo0, s1_lo1, s1_lo2;
    reg       s1_vsync, s1_href, s1_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_hi0 <= 8'd0; s1_hi1 <= 8'd0; s1_hi2 <= 8'd0;
            s1_md0 <= 8'd0; s1_md1 <= 8'd0; s1_md2 <= 8'd0;
            s1_lo0 <= 8'd0; s1_lo1 <= 8'd0; s1_lo2 <= 8'd0;
            s1_vsync <= 1'b0; s1_href <= 1'b0; s1_hsync <= 1'b0;
        end else begin
            s1_hi0 <= r0_hi; s1_hi1 <= r1_hi; s1_hi2 <= r2_hi;
            s1_md0 <= r0_md; s1_md1 <= r1_md; s1_md2 <= r2_md;
            s1_lo0 <= r0_lo; s1_lo1 <= r1_lo; s1_lo2 <= r2_lo;
            s1_vsync <= matrix_vsync;
            s1_href  <= matrix_href;
            s1_hsync <= matrix_hsync;
        end
    end

    // ---- stage 2: median of the three maxima / medians / minima ----
    wire [7:0] hi_med = med3(s1_hi0, s1_hi1, s1_hi2);
    wire [7:0] md_med = med3(s1_md0, s1_md1, s1_md2);
    wire [7:0] lo_med = med3(s1_lo0, s1_lo1, s1_lo2);

    reg [7:0] s2_hi_med, s2_md_med, s2_lo_med;
    reg       s2_vsync, s2_href, s2_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_hi_med <= 8'd0;
            s2_md_med <= 8'd0;
            s2_lo_med <= 8'd0;
            s2_vsync  <= 1'b0;
            s2_href   <= 1'b0;
            s2_hsync  <= 1'b0;
        end else begin
            s2_hi_med <= hi_med;
            s2_md_med <= md_med;
            s2_lo_med <= lo_med;
            s2_vsync  <= s1_vsync;
            s2_href   <= s1_href;
            s2_hsync  <= s1_hsync;
        end
    end

    // ---- stage 3: final median ----
    wire [7:0] median_out = med3(s2_hi_med, s2_md_med, s2_lo_med);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_gray    <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            post_img_gray    <= median_out;
            post_frame_vsync <= s2_vsync;
            post_frame_href  <= s2_href;
            post_frame_hsync <= s2_hsync;
        end
    end

endmodule
