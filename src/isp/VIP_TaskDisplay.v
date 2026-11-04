`timescale 1ns/1ps

// Task selection and final display mixing.
//
//   task 0 : colour image straight through       (colour capture + HDMI)
//   task 1 : grey image                          (RGB -> grey)
//   task 2 : edge map                            (Sobel)
//            pure white  = binarisation result, i.e. gradient above the
//                          threshold. These pixels ARE the binary edge map.
//            dim grey    = gradient below the threshold, shown at 1/8 level so
//                          the weaker detail is visible as context instead of
//                          turning into white speckles.
//   task 3 : left grey / right edge strength split screen
//   task 4 : strictly binary edge map (NMS + double threshold), kept separate
//            from the strength view so both can be shown side by side in a demo
//
// No overlay is drawn on the picture: the threshold level and the active task
// are shown on the board LEDs instead, so the image stays clean.
//
// The colour path and the processed path have different pipeline latency, so
// the sync signals are switched together with the pixels. Changing task while
// the screen is running can tear for a single frame; that is harmless for a
// button driven demo.
module VIP_TaskDisplay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080
    )(
    input               clk,
    input               rst_n,

    input       [3:0]   cfg_task,

    // colour path (task 0)
    input               c_vsync,
    input               c_href,
    input               c_hsync,
    input       [7:0]   c_red,
    input       [7:0]   c_green,
    input       [7:0]   c_blue,

    // processed path (tasks 1 .. 3)
    input               p_vsync,
    input               p_href,
    input               p_hsync,
    input       [7:0]   p_gray,
    input               p_edge,
    input       [7:0]   p_strength,
    input       [7:0]   p_strength_g,   // wide grey ramp (MultiTask v5 style)
    input               p_edge_bin,     // strictly binary edge from the NMS stage
    input               b_vsync,        // NMS-aligned timing for task 5
    input               b_href,
    input               b_hsync,
    input       [7:0]   split_red,
    input       [7:0]   split_green,
    input       [7:0]   split_blue,

    // delayed colour + Sobel edge overlay (task 6)
    input               ov_vsync,
    input               ov_href,
    input               ov_hsync,
    input       [7:0]   ov_red,
    input       [7:0]   ov_green,
    input       [7:0]   ov_blue,

    // DDR status overlay (tasks 7 and 8)
    input               status_vsync,
    input               status_href,
    input               status_hsync,
    input       [7:0]   status_red,
    input       [7:0]   status_green,
    input       [7:0]   status_blue,

    // shape-recognition overlay (task 9)
    input               shape_vsync,
    input               shape_href,
    input               shape_hsync,
    input       [7:0]   shape_red,
    input       [7:0]   shape_green,
    input       [7:0]   shape_blue,

    // icon-recognition overlay (task 10)
    input               icon_vsync,
    input               icon_href,
    input               icon_hsync,
    input       [7:0]   icon_red,
    input       [7:0]   icon_green,
    input       [7:0]   icon_blue,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue
    );

    // ---- processed path pixel for the active task ----
    // five tasks, in the order the user asked for (edge view before the split)
    //   task 3 (index 2) : crisp x4 ramp  (Sobel edge strength)
    //   task 4 (index 3) : split screen
    //   task 5 (index 4) : Canny binary, clean mode
    wire [7:0] edge_pixel = p_strength;
    wire [7:0] bin_pixel = p_edge_bin ? 8'hFF : 8'h00;
    wire [7:0] proc_r = (cfg_task == 4'd2) ? edge_pixel  :
                        (cfg_task == 4'd3) ? split_red   :
                        (cfg_task == 4'd4) ? bin_pixel   : p_gray;
    wire [7:0] proc_g = (cfg_task == 4'd2) ? edge_pixel  :
                        (cfg_task == 4'd3) ? split_green :
                        (cfg_task == 4'd4) ? bin_pixel   : p_gray;
    wire [7:0] proc_b = (cfg_task == 4'd2) ? edge_pixel  :
                        (cfg_task == 4'd3) ? split_blue  :
                        (cfg_task == 4'd4) ? bin_pixel   : p_gray;

    wire       use_colour  = (cfg_task == 4'd0);
    wire       use_status  = (cfg_task == 4'd6) || (cfg_task == 4'd7);
    wire       use_overlay = (cfg_task == 4'd5);
    wire       use_shape   = (cfg_task == 4'd8);
    wire       use_icon    = (cfg_task == 4'd9);
    wire       use_binary  = (cfg_task == 4'd4);

    wire [7:0] out_r = use_colour  ? c_red    :
                       use_status  ? status_red :
                       use_overlay ? ov_red    :
                       use_shape   ? shape_red  :
                       use_icon    ? icon_red   : proc_r;
    wire [7:0] out_g = use_colour  ? c_green  :
                       use_status  ? status_green:
                       use_overlay ? ov_green  :
                       use_shape   ? shape_green:
                       use_icon    ? icon_green : proc_g;
    wire [7:0] out_b = use_colour  ? c_blue   :
                       use_status  ? status_blue:
                       use_overlay ? ov_blue   :
                       use_shape   ? shape_blue :
                       use_icon    ? icon_blue  : proc_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_red     <= 8'd0;
            post_img_green   <= 8'd0;
            post_img_blue    <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            post_img_red     <= out_r;
            post_img_green   <= out_g;
            post_img_blue    <= out_b;
            // The HDMI timing must never jump between processing paths.
            // Sobel timing runs continuously and is used for every task.
            // Task 9 has a three-stage geometry renderer, so use its
            // co-delayed timing instead of the one-stage processed path.
            post_frame_vsync <= use_shape ? shape_vsync :
                                use_icon  ? icon_vsync  : p_vsync;
            post_frame_href  <= use_shape ? shape_href  :
                                use_icon  ? icon_href   : p_href;
            post_frame_hsync <= use_shape ? shape_hsync :
                                use_icon  ? icon_hsync  : p_hsync;
        end
    end

endmodule
