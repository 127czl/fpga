`timescale 1ns/1ps

// Task 8 record-control palm detector.  It runs on the live, colour-corrected
// pixel stream only while Task 8 is idle or recording.  A stable skin-coloured
// hand region toggles the recording state once and then requires the hand to
// leave the ROI before it can fire again.
module VIP_HandPalmLive #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] ROI_X0 = 14'd640,
    parameter [13:0] ROI_X1 = 14'd1279,
    parameter [13:0] ROI_Y0 = 14'd324,
    parameter [13:0] ROI_Y1 = 14'd755,
    parameter [15:0] MIN_SKIN_AREA = 16'd9000,
    parameter [13:0] MIN_HAND_W = 14'd90,
    parameter [13:0] MIN_HAND_H = 14'd90,
    parameter [3:0]  STABLE_FRAMES = 4'd12,
    parameter [3:0]  REARM_FRAMES = 4'd15
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        per_frame_vsync,
    input  wire        per_frame_href,
    input  wire        per_frame_hsync,
    input  wire [7:0]  per_img_red,
    input  wire [7:0]  per_img_green,
    input  wire [7:0]  per_img_blue,

    output reg         gesture_toggle,
    output wire        palm_valid
);

    reg [13:0] x_cnt, y_cnt;
    reg href_d, vsync_d;
    wire href_rise = per_frame_href && !href_d;
    wire vsync_rise = per_frame_vsync && !vsync_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 14'd0;
            y_cnt <= 14'd0;
            href_d <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d <= per_frame_href;
            vsync_d <= per_frame_vsync;
            if (per_frame_href) begin
                if (x_cnt < IMG_HDISP - 1'b1)
                    x_cnt <= x_cnt + 1'b1;
            end else
                x_cnt <= 14'd0;
            if (href_rise && per_frame_vsync) begin
                if (y_cnt < IMG_VDISP - 1'b1)
                    y_cnt <= y_cnt + 1'b1;
            end else if (!per_frame_vsync)
                y_cnt <= 14'd0;
        end
    end

    wire [7:0] rg_max = (per_img_red > per_img_green) ?
                        per_img_red : per_img_green;
    wire [7:0] rg_min = (per_img_red < per_img_green) ?
                        per_img_red : per_img_green;
    wire [7:0] pix_max = (rg_max > per_img_blue) ?
                         rg_max : per_img_blue;
    wire [7:0] pix_min = (rg_min < per_img_blue) ?
                         rg_min : per_img_blue;
    wire [7:0] pix_chroma = pix_max - pix_min;

    wire in_roi = per_frame_vsync && per_frame_href &&
                  (x_cnt >= ROI_X0) && (x_cnt <= ROI_X1) &&
                  (y_cnt >= ROI_Y0) && (y_cnt <= ROI_Y1);

    // Warm-skin rule on the already colour-corrected RGB stream.  The second
    // rule is slightly looser for highlight/shadow areas where the SC2210
    // colour difference collapses.
    wire skin_core =
        (per_img_red >= 8'd55) && (per_img_red <= 8'd250) &&
        (pix_chroma >= 8'd15) &&
        (per_img_red >= per_img_green + 8'd7) &&
        (per_img_red >= per_img_blue + 8'd14) &&
        (per_img_green >= per_img_blue);
    wire skin_soft =
        (per_img_red >= 8'd80) && (per_img_red <= 8'd252) &&
        (pix_chroma >= 8'd20) &&
        (per_img_red >= per_img_green + 8'd4) &&
        (per_img_red >= per_img_blue + 8'd10) &&
        (per_img_green + 8'd10 >= per_img_blue);
    wire skin_raw = in_roi && (skin_core || skin_soft);

    // Three-pixel horizontal majority removes isolated colour noise.
    reg skin_d1, skin_d2;
    wire skin_filter_valid = per_frame_href && (x_cnt != 14'd0);
    wire [13:0] skin_x = x_cnt - 1'b1;
    wire skin_filtered = skin_filter_valid &&
                         ((skin_d2 & skin_d1) |
                          (skin_d2 & skin_raw) |
                          (skin_d1 & skin_raw));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skin_d1 <= 1'b0;
            skin_d2 <= 1'b0;
        end else if (!per_frame_href) begin
            skin_d1 <= 1'b0;
            skin_d2 <= 1'b0;
        end else begin
            skin_d2 <= skin_d1;
            skin_d1 <= skin_raw;
        end
    end

    reg [15:0] skin_count;
    reg [13:0] skin_min_x, skin_max_x;
    reg [13:0] skin_min_y, skin_max_y;
    reg        hand_box_valid;
    reg [13:0] hand_min_x, hand_max_x;
    reg [13:0] hand_min_y, hand_max_y;
    reg [3:0]  scan_count0, scan_count1, scan_count2;
    reg [3:0]  scan_count3, scan_count4;
    reg [3:0]  line_fingers;
    reg [13:0] run_skin_width;
    reg [3:0]  run_gap;
    reg        run_active;
    reg [3:0] stable_frames;
    reg [3:0] absent_frames;
    reg       capture_armed;

    wire [13:0] box_w =
        (skin_max_x >= skin_min_x) ?
        (skin_max_x - skin_min_x + 1'b1) : 14'd0;
    wire [13:0] box_h =
        (skin_max_y >= skin_min_y) ?
        (skin_max_y - skin_min_y + 1'b1) : 14'd0;
    wire skin_box_valid =
        (skin_count >= MIN_SKIN_AREA) &&
        (box_w >= MIN_HAND_W) && (box_h >= MIN_HAND_H) &&
        ({1'b0, box_w} <= ({1'b0, box_h} << 2)) &&
        ({1'b0, box_h} <= ({1'b0, box_w} << 2));

    wire [13:0] hand_h =
        (hand_max_y >= hand_min_y) ?
        (hand_max_y - hand_min_y + 1'b1) : 14'd0;
    wire [13:0] scan_y0 = hand_min_y + (hand_h >> 3);
    wire [13:0] scan_y1 = scan_y0 + (hand_h >> 4);
    wire [13:0] scan_y2 = hand_min_y + (hand_h >> 2);
    wire [13:0] scan_y3 = scan_y2 + (hand_h >> 4);
    wire [13:0] scan_y4 = scan_y2 + (hand_h >> 3);
    wire [13:0] scan_x_lo =
        (hand_min_x + 14'd12 > ROI_X0) ?
        (hand_min_x + 14'd12) : ROI_X0;
    wire [13:0] scan_x_hi =
        (hand_max_x >= 14'd12) ?
        ((hand_max_x - 14'd12 < ROI_X1) ?
         (hand_max_x - 14'd12) : ROI_X1) : ROI_X0;
    wire is_scan_y = hand_box_valid &&
        ((y_cnt == scan_y0) || (y_cnt == scan_y1) ||
         (y_cnt == scan_y2) || (y_cnt == scan_y3) ||
         (y_cnt == scan_y4));
    wire scan_start = per_frame_href && is_scan_y &&
                      (x_cnt == scan_x_lo);
    wire scan_body = per_frame_href && is_scan_y &&
                     (skin_x > scan_x_lo) && (skin_x <= scan_x_hi);
    wire scan_flush = per_frame_href && is_scan_y &&
                      (x_cnt == scan_x_hi + 1'b1);

    function [2:0] classify_run;
        input [13:0] skin_w;
        input [13:0] hand_w;
        reg [13:0] max_w;
        begin
            max_w = hand_w >> 1;
            if (max_w < 14'd24)
                max_w = 14'd24;
            if (max_w > 14'd140)
                max_w = 14'd140;
            classify_run = ((skin_w >= 14'd4) &&
                            (skin_w <= max_w)) ? 3'd1 : 3'd0;
        end
    endfunction

    function [3:0] sat_add4;
        input [3:0] a;
        input [3:0] b;
        reg [4:0] sum;
        begin
            sum = a + b;
            sat_add4 = (sum > 5'd9) ? 4'd9 : sum[3:0];
        end
    endfunction

    wire [13:0] hand_w =
        (hand_max_x >= hand_min_x) ?
        (hand_max_x - hand_min_x + 1'b1) : 14'd0;
    wire current_run_value = classify_run(run_skin_width, hand_w);
    wire [3:0] line_value_with_tail =
        sat_add4(line_fingers, current_run_value);

    function [3:0] second_largest4;
        input [3:0] a;
        input [3:0] b;
        input [3:0] c;
        input [3:0] d;
        input [3:0] e;
        reg [3:0] v0, v1, v2, v3, v4, t;
        begin
            v0=a; v1=b; v2=c; v3=d; v4=e;
            if (v0>v1) begin t=v0; v0=v1; v1=t; end
            if (v1>v2) begin t=v1; v1=v2; v2=t; end
            if (v2>v3) begin t=v2; v2=v3; v3=t; end
            if (v3>v4) begin t=v3; v3=v4; v4=t; end
            if (v0>v1) begin t=v0; v0=v1; v1=t; end
            if (v1>v2) begin t=v1; v1=v2; v2=t; end
            if (v2>v3) begin t=v2; v2=v3; v3=t; end
            if (v0>v1) begin t=v0; v0=v1; v1=t; end
            if (v1>v2) begin t=v1; v1=v2; v2=t; end
            if (v0>v1) begin t=v0; v0=v1; v1=t; end
            second_largest4 = v3;
        end
    endfunction

    wire [3:0] finger_second =
        second_largest4(scan_count0, scan_count1, scan_count2,
                        scan_count3, scan_count4);
    wire frame_candidate =
        skin_box_valid && hand_box_valid && (finger_second >= 4'd4);

    assign palm_valid = (stable_frames >= STABLE_FRAMES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gesture_toggle <= 1'b0;
            skin_count <= 16'd0;
            skin_min_x <= 14'h3FFF;
            skin_max_x <= 14'd0;
            skin_min_y <= 14'h3FFF;
            skin_max_y <= 14'd0;
            hand_box_valid <= 1'b0;
            hand_min_x <= 14'd0;
            hand_max_x <= 14'd0;
            hand_min_y <= 14'd0;
            hand_max_y <= 14'd0;
            scan_count0 <= 4'd0;
            scan_count1 <= 4'd0;
            scan_count2 <= 4'd0;
            scan_count3 <= 4'd0;
            scan_count4 <= 4'd0;
            line_fingers <= 4'd0;
            run_skin_width <= 14'd0;
            run_gap <= 4'd0;
            run_active <= 1'b0;
            stable_frames <= 4'd0;
            absent_frames <= 4'd0;
            capture_armed <= 1'b0;
        end else begin
            if (vsync_rise) begin
                if (frame_candidate) begin
                    absent_frames <= 4'd0;
                    if (stable_frames < (STABLE_FRAMES - 1'b1))
                        stable_frames <= stable_frames + 1'b1;
                    else if (stable_frames == (STABLE_FRAMES - 1'b1)) begin
                        stable_frames <= STABLE_FRAMES;
                        if (capture_armed) begin
                            gesture_toggle <= ~gesture_toggle;
                            capture_armed <= 1'b0;
                        end
                    end
                end else begin
                    stable_frames <= 4'd0;
                    if (!capture_armed) begin
                        if (absent_frames < REARM_FRAMES)
                            absent_frames <= absent_frames + 1'b1;
                        if (absent_frames >= (REARM_FRAMES - 1'b1))
                            capture_armed <= 1'b1;
                    end
                end

                if (skin_box_valid) begin
                    hand_box_valid <= 1'b1;
                    hand_min_x <= skin_min_x;
                    hand_max_x <= skin_max_x;
                    hand_min_y <= skin_min_y;
                    hand_max_y <= skin_max_y;
                end else
                    hand_box_valid <= 1'b0;

                skin_count <= 16'd0;
                skin_min_x <= 14'h3FFF;
                skin_max_x <= 14'd0;
                skin_min_y <= 14'h3FFF;
                skin_max_y <= 14'd0;
            end else if (skin_filtered &&
                         (skin_x >= ROI_X0) && (skin_x <= ROI_X1) &&
                         (y_cnt >= ROI_Y0) && (y_cnt <= ROI_Y1)) begin
                if (skin_count != 16'hFFFF)
                    skin_count <= skin_count + 1'b1;
                if (skin_x < skin_min_x)
                    skin_min_x <= skin_x;
                if (skin_x > skin_max_x)
                    skin_max_x <= skin_x;
                if (y_cnt < skin_min_y)
                    skin_min_y <= y_cnt;
                if (y_cnt > skin_max_y)
                    skin_max_y <= y_cnt;
            end

            if (scan_start) begin
                line_fingers <= 4'd0;
                run_skin_width <= 14'd0;
                run_gap <= 4'd0;
                run_active <= 1'b0;
            end else if (scan_body) begin
                if (skin_filtered) begin
                    if (!run_active) begin
                        run_active <= 1'b1;
                        run_skin_width <= 14'd1;
                    end else if (run_skin_width != 14'h3FFF)
                        run_skin_width <= run_skin_width + 1'b1;
                    run_gap <= 4'd0;
                end else if (run_active) begin
                    if (run_gap < 4'd3)
                        run_gap <= run_gap + 1'b1;
                    else begin
                        line_fingers <=
                            sat_add4(line_fingers, current_run_value);
                        run_active <= 1'b0;
                        run_skin_width <= 14'd0;
                        run_gap <= 4'd0;
                    end
                end
            end else if (scan_flush) begin
                if (y_cnt == scan_y0)
                    scan_count0 <= line_value_with_tail;
                else if (y_cnt == scan_y1)
                    scan_count1 <= line_value_with_tail;
                else if (y_cnt == scan_y2)
                    scan_count2 <= line_value_with_tail;
                else if (y_cnt == scan_y3)
                    scan_count3 <= line_value_with_tail;
                else
                    scan_count4 <= line_value_with_tail;
                line_fingers <= 4'd0;
                run_skin_width <= 14'd0;
                run_gap <= 4'd0;
                run_active <= 1'b0;
            end
        end
    end

endmodule
