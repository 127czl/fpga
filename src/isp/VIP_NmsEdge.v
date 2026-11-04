`timescale 1ns/1ps

// Canny style edge finalisation on top of the Sobel gradient.
//
//  1. the gradient direction is quantised into four bins
//  2. the magnitude, the grey image and the direction each go through their
//     own 3x3 window built from the same module with the same parameters, so
//     the three stay pixel locked without any hand tuned delay matching
//  3. non maximum suppression keeps a pixel only when its magnitude is at
//     least as large as the two neighbours along the gradient direction.
//     This is what thins a thick gradient blob down to a single pixel edge
//  4. double threshold with a single pass hysteresis: above the high
//     threshold the pixel is a strong edge; between low and high it survives
//     only when one of its eight neighbours is already above the high
//     threshold. That removes isolated noise specks and bridges small gaps
//
// Direction bins (image coordinates, x to the right, y downwards):
//   0  |Gx|*2 <  |Gy|   gradient mostly vertical   -> compare up / down
//   1  |Gy|*2 <  |Gx|   gradient mostly horizontal -> compare left / right
//   2  signs equal      gradient points down-right -> compare tl / br
//   3  signs differ     gradient points up-right   -> compare tr / bl
module VIP_NmsEdge #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    // Standard Canny hysteresis: weak pixels survive only when they touch a
    // strong neighbour.  This is the structure used by mature open-source FPGA
    // Canny implementations; no non-standard length filter is added here.
    parameter        USE_HYSTERESIS = 1'b1
    )(
    input               clk,
    input               rst_n,

    input       [7:0]   cfg_thr_high,       // on the 8 bit magnitude scale
    input       [7:0]   cfg_thr_low,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_mag,
    input       [7:0]   per_img_gray,
    input       [11:0]  per_img_gx,
    input       [11:0]  per_img_gy,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_gray,
    output reg  [7:0]   post_img_edge,      // 255 = edge, dim value = magnitude
    output reg          post_img_edge_bin
    );

    // ---------------- direction quantisation ----------------
    wire [11:0] ax = per_img_gx[11] ? (~per_img_gx + 12'd1) : per_img_gx;
    wire [11:0] ay = per_img_gy[11] ? (~per_img_gy + 12'd1) : per_img_gy;

    wire [1:0] dir =
        ({1'b0, ax} <  {ay, 1'b0})         ? 2'd0 :   // ax*2 < ay
        ({1'b0, ay} <  {ax, 1'b0})         ? 2'd1 :   // ay*2 < ax
        (per_img_gx[11] == per_img_gy[11]) ? 2'd2 : 2'd3;

    // ---------------- three aligned 3x3 windows ----------------
    wire        mag_vsync, mag_href, mag_hsync;
    wire [7:0]  m11, m12, m13, m21, m22, m23, m31, m32, m33;

    VIP_Matrix_Generate_3X3_8Bit #(
        .IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP)
    ) u_mag_matrix (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(per_frame_vsync),
        .per_frame_href (per_frame_href),
        .per_frame_hsync(per_frame_hsync),
        .per_img_Y(per_img_mag),
        .matrix_frame_vsync(mag_vsync),
        .matrix_frame_href (mag_href),
        .matrix_frame_hsync(mag_hsync),
        .matrix_p11(m11), .matrix_p12(m12), .matrix_p13(m13),
        .matrix_p21(m21), .matrix_p22(m22), .matrix_p23(m23),
        .matrix_p31(m31), .matrix_p32(m32), .matrix_p33(m33)
    );

    wire        dir_vsync, dir_href, dir_hsync;
    wire [7:0]  d11, d12, d13, d21, d22, d23, d31, d32, d33;

    VIP_Matrix_Generate_3X3_8Bit #(
        .IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP)
    ) u_dir_matrix (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(per_frame_vsync),
        .per_frame_href (per_frame_href),
        .per_frame_hsync(per_frame_hsync),
        .per_img_Y({6'b000000, dir}),
        .matrix_frame_vsync(dir_vsync),
        .matrix_frame_href (dir_href),
        .matrix_frame_hsync(dir_hsync),
        .matrix_p11(d11), .matrix_p12(d12), .matrix_p13(d13),
        .matrix_p21(d21), .matrix_p22(d22), .matrix_p23(d23),
        .matrix_p31(d31), .matrix_p32(d32), .matrix_p33(d33)
    );

    wire        gry_vsync, gry_href, gry_hsync;
    wire [7:0]  g11, g12, g13, g21, g22, g23, g31, g32, g33;

    VIP_Matrix_Generate_3X3_8Bit #(
        .IMG_HDISP(IMG_HDISP), .IMG_VDISP(IMG_VDISP)
    ) u_gry_matrix (
        .clk(clk), .rst_n(rst_n),
        .per_frame_vsync(per_frame_vsync),
        .per_frame_href (per_frame_href),
        .per_frame_hsync(per_frame_hsync),
        .per_img_Y(per_img_gray),
        .matrix_frame_vsync(gry_vsync),
        .matrix_frame_href (gry_href),
        .matrix_frame_hsync(gry_hsync),
        .matrix_p11(g11), .matrix_p12(g12), .matrix_p13(g13),
        .matrix_p21(g21), .matrix_p22(g22), .matrix_p23(g23),
        .matrix_p31(g31), .matrix_p32(g32), .matrix_p33(g33)
    );

    // ---------------- non maximum suppression ----------------
    // the two neighbours along the gradient direction, selected by the centre
    // direction bin of the direction window
    wire [7:0] nbr_a = (d22[1:0] == 2'd0) ? m12 :
                       (d22[1:0] == 2'd1) ? m21 :
                       (d22[1:0] == 2'd2) ? m11 : m13;

    wire [7:0] nbr_b = (d22[1:0] == 2'd0) ? m32 :
                       (d22[1:0] == 2'd1) ? m23 :
                       (d22[1:0] == 2'd2) ? m33 : m31;

    // Plateau-aware non-maximum suppression: reject a flat region, but keep
    // one representative pixel when two neighbours are exactly equal.
    wire       nms_pass = ((m22 > nbr_a) && (m22 >= nbr_b)) ||
                          ((m22 >= nbr_a) && (m22 > nbr_b));
    wire [7:0] nms_mag  = nms_pass ? m22 : 8'h00;

    // ---------------- double threshold + one pass hysteresis ----------------
    wire strong = (nms_mag > cfg_thr_high);
    wire weak   = (nms_mag > cfg_thr_low);

    // a weak pixel survives when any of the eight raw neighbours is strong
    wire [3:0] nbr_strong_cnt =
        {3'b000, (m11 > cfg_thr_high)} + {3'b000, (m12 > cfg_thr_high)} +
        {3'b000, (m13 > cfg_thr_high)} + {3'b000, (m21 > cfg_thr_high)} +
        {3'b000, (m23 > cfg_thr_high)} + {3'b000, (m31 > cfg_thr_high)} +
        {3'b000, (m32 > cfg_thr_high)} + {3'b000, (m33 > cfg_thr_high)};

    wire nbr_any    = (nbr_strong_cnt != 4'd0);

    // Standard double-threshold hysteresis: weak pixels survive only when an
    // adjacent pixel already belongs to the strong-edge class.
    wire edge_final = USE_HYSTERESIS ? (strong || (weak && nbr_any)) : strong;

    // ---- soft threshold display ----
    // A hard binary step gives jagged edges. Below the low threshold the pixel
    // is black; above it the magnitude is stretched by two so the transition
    // from faint to full edge is a short grey ramp instead of a sudden jump.
    // The threshold decision is unchanged, only the way it is shown is softer.
    wire [8:0] soft_span = {1'b0, m22} - {1'b0, cfg_thr_low};
    wire [8:0] soft_val  = soft_span << 1;
    wire [7:0] soft_disp = (m22 <= cfg_thr_low)        ? 8'h00 :
                           (soft_val > 9'd255)         ? 8'hFF : soft_val[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_gray     <= 8'd0;
            post_img_edge     <= 8'd0;
            post_img_edge_bin <= 1'b0;
            post_frame_vsync  <= 1'b0;
            post_frame_href   <= 1'b0;
            post_frame_hsync  <= 1'b0;
        end else begin
            post_img_gray     <= g22;
            // Keep the binary output inside the active pixel window.  The
            // magnitude window provides the aligned timing for edge_final.
            post_img_edge_bin <= mag_href ? edge_final : 1'b0;
            // white for the finalised single pixel edge, with the soft
            // threshold image underneath so the edge body stays visible
            post_img_edge     <= edge_final ? 8'hFF : soft_disp;
            post_frame_vsync  <= mag_vsync;
            post_frame_href   <= mag_href;
            post_frame_hsync  <= mag_hsync;
        end
    end

endmodule
