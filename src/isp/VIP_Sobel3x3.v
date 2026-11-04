`timescale 1ns/1ps

// 3x3 Sobel edge detector.
//
//   Gx = (p13 + 2*p23 + p33) - (p11 + 2*p21 + p31)
//   Gy = (p31 + 2*p32 + p33) - (p11 + 2*p12 + p13)
//   G  = |Gx| + |Gy|                  absolute sum, no square root
//   edge = (G > threshold)
//
// The x2 terms are shifts, so no multiplier or divider is needed.
// Two pipeline stages follow the 3x3 window; the aligned grey output (the
// window centre p22) is registered alongside the edge flag, so the grey image
// and the edge map stay pixel locked and can be mixed directly.
module VIP_Sobel3x3 #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080
    )(
    input               clk,
    input               rst_n,

    input       [10:0]  cfg_threshold,      // 0 .. 2040

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_gray,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_gray,      // window centre, aligned with edge
    output reg          post_img_edge,
    output reg  [7:0]   post_img_strength,  // edge strength, /4 with saturation
    output reg  [7:0]   post_img_strength_g,// wide grey ramp (MultiTask v5 style)
    output reg  [7:0]   post_grad_lin,      // linear magnitude /8, for Canny NMS
    output reg  [12:0]  post_grad_mag,      // raw |Gx|+|Gy|, for the AGC block
    output reg  [11:0]  post_gx,            // signed Gx, for the NMS direction
    output reg  [11:0]  post_gy             // signed Gy, for the NMS direction
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

    // ---- stage 1: partial column sums ----
    wire [9:0] gx_pos_sum = p13 + {p23, 1'b0} + p33;
    wire [9:0] gx_neg_sum = p11 + {p21, 1'b0} + p31;
    wire [9:0] gy_pos_sum = p31 + {p32, 1'b0} + p33;
    wire [9:0] gy_neg_sum = p11 + {p12, 1'b0} + p13;

    // ---- border mask ----
    // The window generator zeroes the first two columns of every line and the
    // line buffers still hold the previous frame during the first two lines of
    // a frame, so those pixels would produce spurious white specks along the
    // top and left edge. Force them to "no edge" instead.
    //
    // IMPORTANT: in this design vsync is "frame valid": HIGH while the active
    // picture is being sent and LOW during the frame sync period (see the
    // comment on image_out_vsync in the CSI receiver). The line counter must
    // therefore be cleared while vsync is LOW. Clearing it while vsync is HIGH
    // would hold the counter at zero for the whole frame and mask every edge.
    reg [11:0] x_pos;
    reg [11:0] y_pos;
    reg        m_href_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_pos    <= 12'd0;
            y_pos    <= 12'd0;
            m_href_r <= 1'b0;
        end else begin
            m_href_r <= matrix_href;

            if (!matrix_href)
                x_pos <= 12'd0;
            else if (x_pos < IMG_HDISP - 1'b1)
                x_pos <= x_pos + 1'b1;

            if (!matrix_vsync)
                y_pos <= 12'd0;
            else if (matrix_href && !m_href_r)
                y_pos <= y_pos + 1'b1;
        end
    end

    wire border_pixel = (x_pos < 12'd2) || (y_pos < 12'd2);

    reg [9:0] s1_gx_pos, s1_gx_neg, s1_gy_pos, s1_gy_neg;
    reg [7:0] s1_gray;
    reg       s1_vsync, s1_href, s1_hsync;
    reg       s1_border;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_gx_pos <= 10'd0;
            s1_gx_neg <= 10'd0;
            s1_gy_pos <= 10'd0;
            s1_gy_neg <= 10'd0;
            s1_gray   <= 8'd0;
            s1_vsync  <= 1'b0;
            s1_href   <= 1'b0;
            s1_hsync  <= 1'b0;
            s1_border <= 1'b0;
        end else begin
            s1_gx_pos <= gx_pos_sum;
            s1_gx_neg <= gx_neg_sum;
            s1_gy_pos <= gy_pos_sum;
            s1_gy_neg <= gy_neg_sum;
            s1_gray   <= p22;
            s1_vsync  <= matrix_vsync;
            s1_href   <= matrix_href;
            s1_hsync  <= matrix_hsync;
            s1_border <= border_pixel;
        end
    end

    // ---- stage 2: signed difference, absolute value, sum, threshold ----
    wire signed [11:0] gx_sum = $signed({2'b00, s1_gx_pos}) - $signed({2'b00, s1_gx_neg});
    wire signed [11:0] gy_sum = $signed({2'b00, s1_gy_pos}) - $signed({2'b00, s1_gy_neg});

    wire [11:0] gx_abs = gx_sum[11] ? (~gx_sum + 12'd1) : gx_sum;
    wire [11:0] gy_abs = gy_sum[11] ? (~gy_sum + 12'd1) : gy_sum;

    wire [12:0] grad_mag = {1'b0, gx_abs} + {1'b0, gy_abs};

    // Edge strength above the threshold.
    //
    // The threshold is SUBTRACTED, not merely used as a pass/block gate. With
    // a plain gate, raising the threshold only removes the dimmest pixels and
    // every bright edge stays exactly as bright, so the key adjustment looks
    // like it does nothing. Subtracting makes the whole edge map respond:
    // raise the threshold and everything dims, lower it and the edges
    // brighten and multiply.
    wire [12:0] strength_over = (grad_mag > {2'b00, cfg_threshold})
                                ? (grad_mag - {2'b00, cfg_threshold}) : 13'd0;
    // x4 gain, restored. This is the rendering the user judged best: it looks
    // more like real edges than the Canny binary map and is almost free of
    // noise, because weak gradients land under the threshold and are cut,
    // while anything 64 above it pops to clean white.
    wire [14:0] strength_x4   = {2'b00, strength_over} << 2;
    wire [7:0]  strength_now  = (strength_x4 > 15'd255) ? 8'hFF : strength_x4[7:0];

    // wide grey ramp version: gradient / 4, no threshold subtraction, so the
    // grey levels stay spread out instead of saturating immediately
    wire [7:0]  gray_strength = (grad_mag[12:10] != 3'b000) ? 8'hFF : grad_mag[9:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_gray    <= 8'd0;
            post_img_edge    <= 1'b0;
            post_img_strength <= 8'd0;
            post_img_strength_g <= 8'd0;
            post_grad_mag    <= 13'd0;
            post_gx          <= 12'd0;
            post_gy          <= 12'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            post_img_gray    <= s1_gray;
            post_img_edge    <= (grad_mag > {2'b00, cfg_threshold}) && !s1_border;
            // edge strength display: gradient above the threshold, doubled.
            // Border pixels are zeroed because their 3x3 window is incomplete.
            post_img_strength <= s1_border ? 8'h00 : strength_now;
            post_img_strength_g <= (s1_border || (grad_mag <= {2'b00, cfg_threshold}))
                                   ? 8'h00 : gray_strength;
            // The Canny NMS must see a linear magnitude.  Using the display
            // strength here is wrong because that signal subtracts the
            // threshold, multiplies by four and saturates at 255.  A small
            // noise gradient and a strong edge then collapse to the same 255
            // plateau, so NMS keeps many equal-valued noise pixels and the
            // binary map looks like flashing snow.  grad_mag/8 keeps the full
            // 0..2040 range as 0..255 for the 8-bit matrix window.
            post_grad_lin    <= s1_border ? 8'h00 : grad_mag[10:3];
            post_grad_mag    <= s1_border ? 13'd0 : grad_mag;
            post_gx          <= gx_sum;
            post_gy          <= gy_sum;
            post_frame_vsync <= s1_vsync;
            post_frame_href  <= s1_href;
            post_frame_hsync <= s1_hsync;
        end
    end

endmodule
