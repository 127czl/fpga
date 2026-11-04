`timescale 1ns/1ps

// RGB888 -> 8-bit luma.
// BT.601 weighting: Y = (77*R + 150*G + 29*B) >> 8.
// The three weights add up to 256, so no extra scaling is needed and a full
// white pixel maps exactly to 255.
module VIP_RGB888_Gray (
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
    output reg  [7:0]   post_img_gray
);

    // 255 * 256 = 65280, so 16 bits hold the largest possible sum.
    wire [15:0] luma_sum = per_img_red   * 16'd77
                         + per_img_green * 16'd150
                         + per_img_blue  * 16'd29;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_gray    <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            post_img_gray    <= luma_sum[15:8];
            post_frame_vsync <= per_frame_vsync;
            post_frame_href  <= per_frame_href;
            post_frame_hsync <= per_frame_hsync;
        end
    end

endmodule
