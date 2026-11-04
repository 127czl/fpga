`timescale 1ns/1ps

// 3x3 Gaussian pre-smoothing, the first step of a Canny pipeline.
//
//    1 2 1
//    2 4 2   / 16
//    1 2 1
//
// All nine terms are built from shifts and adds, no multiplier is used.
// This is what makes the non maximum suppression stage behave: a median
// filter removes isolated spots but leaves the fine grain sensor noise, and
// NMS on grain produces broken dotted edges. Canny smooths with a Gaussian
// first for exactly this reason.
module VIP_Gauss3x3 #(
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

    // corners x1, edges x2, centre x4. Largest possible sum is 16*255 = 4080
    // so 12 bits are enough.
    wire [11:0] gauss_sum =
          {4'b0, p11} + {3'b0, p12, 1'b0} + {4'b0, p13}
        + {3'b0, p21, 1'b0} + {2'b0, p22, 2'b00} + {3'b0, p23, 1'b0}
        + {4'b0, p31} + {3'b0, p32, 1'b0} + {4'b0, p33};

    // two pipeline stages: one for the sum, one for the shift and the syncs
    reg [11:0] s1_sum;
    reg        s1_vsync, s1_href, s1_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_sum   <= 12'd0;
            s1_vsync <= 1'b0;
            s1_href  <= 1'b0;
            s1_hsync <= 1'b0;
        end else begin
            s1_sum   <= gauss_sum;
            s1_vsync <= matrix_vsync;
            s1_href  <= matrix_href;
            s1_hsync <= matrix_hsync;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_gray    <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            // /16, and the sum can never exceed 4080 so the top bits are safe
            post_img_gray    <= (s1_sum[11:4] > 8'd255) ? 8'd255 : s1_sum[11:4];
            post_frame_vsync <= s1_vsync;
            post_frame_href  <= s1_href;
            post_frame_hsync <= s1_hsync;
        end
    end

endmodule
